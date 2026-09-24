"""Tests for docker/configure_2fa.py — the ERP two-factor authentication policy (VC-644).

Runs on plain Python with no Frappe install: a fake `frappe` holds System Settings and the
Role table in memory and records every write.

Run:  python3 -m unittest discover -s docker/__tests__ -p 'test_*.py'
"""

import io
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import configure_2fa as c2fa


class FakeDB:
	def __init__(self, settings, roles):
		self.settings = dict(settings)
		self.roles = dict(roles)
		self.writes = []
		self.committed = False
		self.rolled_back = False
		self.drop_writes_to = set()
		self.drop_role_writes = False
		self.disabled_roles = set()

	def get_single_value(self, doctype, field):
		assert doctype == "System Settings"
		return self.settings.get(field)

	def set_single_value(self, doctype, field, value):
		assert doctype == "System Settings"
		self.writes.append(("settings", field, value))
		if field not in self.drop_writes_to:
			self.settings[field] = value

	def set_value(self, doctype, name, field, value):
		assert doctype == "Role" and field == "two_factor_auth"
		self.writes.append(("role", name, value))
		if not self.drop_role_writes:
			self.roles[name] = value

	def commit(self):
		self.committed = True

	def rollback(self):
		self.rolled_back = True


class FakeFrappe:
	def __init__(self, settings=None, roles=None):
		self.db = FakeDB(
			settings
			if settings is not None
			else {"enable_two_factor_auth": 0, "two_factor_method": "OTP App"},
			roles if roles is not None else {"All": 0, "Guest": 0, "System Manager": 0, "Employee": 0},
		)
		self.destroyed = False

	def get_all(self, doctype, filters=None, pluck=None):
		assert doctype == "Role" and pluck == "name"
		if filters == {"two_factor_auth": 1}:
			return [name for name, flag in self.db.roles.items() if flag]
		assert filters == {"disabled": 0}
		return [name for name in self.db.roles if name not in self.db.disabled_roles]

	def init(self, site, sites_path):
		self.site = site

	def connect(self):
		pass

	def destroy(self):
		self.destroyed = True


def enforced(fake):
	return {name for name, flag in fake.db.roles.items() if flag}


class ParseEnvTests(unittest.TestCase):
	def test_defaults_enforce_authenticator_app_2fa_for_every_user(self):
		self.assertEqual(c2fa.parse_env({}), {"enabled": True, "roles": ["All"], "issuer": "SAH ERP"})

	def test_role_list_is_trimmed_and_deduplicated(self):
		policy = c2fa.parse_env({"FRAPPE_2FA_ROLES": " 2FA Pilot , ,System Manager,2FA Pilot "})
		self.assertEqual(policy["roles"], ["2FA Pilot", "System Manager"])

	def test_role_list_that_names_nothing_is_rejected(self):
		with self.assertRaises(c2fa.PolicyError):
			c2fa.parse_env({"FRAPPE_2FA_ROLES": " , "})

	def test_enabled_flag_other_than_0_or_1_is_rejected(self):
		for value in ("yes", "true", "2", "off"):
			with self.subTest(value=value), self.assertRaises(c2fa.PolicyError):
				c2fa.parse_env({"FRAPPE_2FA_ENABLED": value})

	def test_empty_values_fall_back_to_defaults(self):
		policy = c2fa.parse_env({"FRAPPE_2FA_ENABLED": "", "FRAPPE_2FA_ROLES": "", "FRAPPE_2FA_ISSUER": "  "})
		self.assertEqual(policy, {"enabled": True, "roles": ["All"], "issuer": "SAH ERP"})


class ApplyPolicyTests(unittest.TestCase):
	def test_default_policy_turns_on_otp_app_2fa_for_all_users(self):
		fake = FakeFrappe(
			settings={
				"enable_two_factor_auth": 0,
				"two_factor_method": "SMS",
				"bypass_2fa_for_retricted_ip_users": 1,
				"login_with_email_link": 1,
			}
		)
		c2fa.apply_policy(fake, c2fa.parse_env({}))
		self.assertEqual(
			fake.db.settings,
			{
				"enable_two_factor_auth": 1,
				"two_factor_method": "OTP App",
				"otp_issuer_name": "SAH ERP",
				"bypass_2fa_for_retricted_ip_users": 0,
				"login_with_email_link": 0,
			},
		)
		self.assertEqual(enforced(fake), {"All"})

	def test_pilot_rollout_enforces_only_the_pilot_role(self):
		fake = FakeFrappe(roles={"All": 1, "2FA Pilot": 0, "Employee": 0})
		c2fa.apply_policy(fake, c2fa.parse_env({"FRAPPE_2FA_ROLES": "2FA Pilot"}))
		self.assertEqual(enforced(fake), {"2FA Pilot"})

	def test_roles_outside_the_policy_have_2fa_switched_off(self):
		fake = FakeFrappe(roles={"All": 0, "System Manager": 1, "Employee": 1})
		c2fa.apply_policy(fake, c2fa.parse_env({}))
		self.assertEqual(enforced(fake), {"All"})

	def test_second_run_on_a_compliant_site_writes_nothing(self):
		fake = FakeFrappe()
		c2fa.apply_policy(fake, c2fa.parse_env({}))
		fake.db.writes.clear()
		changes = c2fa.apply_policy(fake, c2fa.parse_env({}))
		self.assertEqual((changes, fake.db.writes), ([], []))

	def test_break_glass_switches_2fa_off_and_leaves_roles_alone(self):
		fake = FakeFrappe(
			settings={"enable_two_factor_auth": 1, "two_factor_method": "OTP App"},
			roles={"All": 1, "Employee": 0},
		)
		c2fa.apply_policy(fake, c2fa.parse_env({"FRAPPE_2FA_ENABLED": "0"}))
		self.assertEqual(fake.db.settings["enable_two_factor_auth"], 0)
		self.assertEqual(fake.db.writes, [("settings", "enable_two_factor_auth", 0)])

	def test_unknown_role_is_rejected_before_anything_is_written(self):
		fake = FakeFrappe()
		with self.assertRaisesRegex(c2fa.PolicyError, "Typo Role"):
			c2fa.apply_policy(fake, c2fa.parse_env({"FRAPPE_2FA_ROLES": "All,Typo Role"}))
		self.assertEqual(fake.db.writes, [])

	def test_custom_issuer_is_written(self):
		fake = FakeFrappe()
		c2fa.apply_policy(fake, c2fa.parse_env({"FRAPPE_2FA_ISSUER": "SAH-ERP-Staging"}))
		self.assertEqual(fake.db.settings["otp_issuer_name"], "SAH-ERP-Staging")

	def test_break_glass_works_even_when_the_role_list_is_stale(self):
		fake = FakeFrappe(settings={"enable_two_factor_auth": 1}, roles={"All": 1})
		c2fa.apply_policy(fake, c2fa.parse_env({"FRAPPE_2FA_ENABLED": "0", "FRAPPE_2FA_ROLES": "Gone Role"}))
		self.assertEqual(fake.db.settings["enable_two_factor_auth"], 0)

	def test_disabled_role_is_rejected_because_it_enforces_nothing(self):
		fake = FakeFrappe(roles={"All": 0, "2FA-Pilot": 0})
		fake.db.disabled_roles = {"2FA-Pilot"}
		with self.assertRaisesRegex(c2fa.PolicyError, "2FA-Pilot"):
			c2fa.apply_policy(fake, c2fa.parse_env({"FRAPPE_2FA_ROLES": "2FA-Pilot"}))
		self.assertEqual(fake.db.writes, [])

	def test_guest_is_rejected_because_it_never_signs_in(self):
		fake = FakeFrappe()
		with self.assertRaisesRegex(c2fa.PolicyError, "Guest"):
			c2fa.apply_policy(fake, c2fa.parse_env({"FRAPPE_2FA_ROLES": "Guest"}))
		self.assertEqual(fake.db.writes, [])

	def test_a_role_flag_that_does_not_stick_fails_the_read_back(self):
		fake = FakeFrappe()
		fake.db.drop_role_writes = True
		with self.assertRaisesRegex(c2fa.PolicyError, "read-back mismatch on 2FA roles"):
			c2fa.apply_policy(fake, c2fa.parse_env({}))

	def test_a_setting_that_does_not_stick_fails_the_read_back(self):
		fake = FakeFrappe()
		fake.db.drop_writes_to = {"enable_two_factor_auth"}
		with self.assertRaisesRegex(c2fa.PolicyError, "read-back mismatch on enable_two_factor_auth"):
			c2fa.apply_policy(fake, c2fa.parse_env({}))


class MainTests(unittest.TestCase):
	def run_main(self, fake, env):
		out, err = io.StringIO(), io.StringIO()
		with mock.patch.dict(sys.modules, {"frappe": fake}), mock.patch.dict(os.environ, env, clear=True):
			with redirect_stdout(out), redirect_stderr(err):
				code = c2fa.main(["configure_2fa.py", "erp.example"])
		return code, out.getvalue(), err.getvalue()

	def test_success_commits_and_reports_the_policy(self):
		fake = FakeFrappe()
		code, out, _ = self.run_main(fake, {})
		self.assertEqual(code, 0)
		self.assertEqual(fake.site, "erp.example")
		self.assertTrue(fake.db.committed and fake.destroyed)
		self.assertIn("2FA policy applied — enabled for roles: All", out)
		self.assertIn("  role All: 2FA on", out)

	def test_break_glass_reports_2fa_disabled(self):
		fake = FakeFrappe(settings={"enable_two_factor_auth": 1})
		code, out, _ = self.run_main(fake, {"FRAPPE_2FA_ENABLED": "0"})
		self.assertEqual(code, 0)
		self.assertIn("2FA policy applied — DISABLED; 1 change(s)", out)

	def test_missing_site_argument_is_a_usage_error(self):
		err = io.StringIO()
		with redirect_stderr(err):
			code = c2fa.main(["configure_2fa.py"])
		self.assertEqual(code, 2)
		self.assertIn("usage", err.getvalue())

	def test_unexpected_error_rolls_back_closes_and_propagates(self):
		fake = FakeFrappe()

		def boom(*args, **kwargs):
			raise RuntimeError("database went away")

		fake.get_all = boom
		with self.assertRaisesRegex(RuntimeError, "database went away"):
			self.run_main(fake, {})
		self.assertTrue(fake.db.rolled_back and fake.destroyed)
		self.assertFalse(fake.db.committed)

	def test_policy_error_rolls_back_and_exits_non_zero(self):
		fake = FakeFrappe()
		code, _, err = self.run_main(fake, {"FRAPPE_2FA_ROLES": "Typo Role"})
		self.assertEqual(code, 1)
		self.assertTrue(fake.db.rolled_back and fake.destroyed)
		self.assertFalse(fake.db.committed)
		self.assertIn("Typo Role", err)

	def test_bad_env_exits_before_touching_the_site(self):
		fake = FakeFrappe()
		code, _, err = self.run_main(fake, {"FRAPPE_2FA_ENABLED": "yes"})
		self.assertEqual(code, 1)
		self.assertFalse(hasattr(fake, "site"))
		self.assertIn("FRAPPE_2FA_ENABLED", err)


if __name__ == "__main__":
	unittest.main()
