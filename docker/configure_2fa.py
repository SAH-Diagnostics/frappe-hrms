"""Enforce the ERP's two-factor authentication policy on every container boot.

Run by docker/init.sh with the bench's own interpreter, from the bench `sites` directory:

    ../env/bin/python /workspace/configure_2fa.py <site>

The policy is declarative and comes from the environment, so a rebuilt instance always
comes up with authenticator-app 2FA on, and a change made by hand in the UI is put back
on the next deploy:

    FRAPPE_2FA_ENABLED  1 (default) enforces the policy; 0 switches 2FA off (break-glass).
    FRAPPE_2FA_ROLES    Comma-separated roles whose users must use 2FA. Default "All",
                        i.e. every user. A narrower list (a pilot role) is how the rollout
                        is staged; every role not in the list has 2FA switched off.
    FRAPPE_2FA_ISSUER   Account label shown in the authenticator app. Default "SAH ERP".

The deploy `source`s the unquoted secrets file, so an override containing a space (a role
such as "System Manager", an issuer such as "SAH ERP") must be stored in Secrets Manager
wrapped in literal double quotes, or every deploy step fails. Prefer space-free values.

"Login with email link" is switched off while 2FA is enforced: it signs the user in without
the second factor.

Settings are written field by field with set_single_value rather than by saving the
System Settings document: a save re-runs validation of unrelated settings, which could
block the 2FA change, and switches 2FA on for the "All" role as a side effect, which
would defeat a pilot rollout.
"""

import os
import sys

SETTINGS_DOCTYPE = "System Settings"
DEFAULT_ROLES = "All"
DEFAULT_ISSUER = "SAH ERP"


class PolicyError(Exception):
	pass


def parse_env(env):
	enabled = (env.get("FRAPPE_2FA_ENABLED") or "1").strip()
	if enabled not in ("0", "1"):
		raise PolicyError(f"FRAPPE_2FA_ENABLED must be 0 or 1, got {enabled!r}")

	roles = []
	for role in (env.get("FRAPPE_2FA_ROLES") or DEFAULT_ROLES).split(","):
		role = role.strip()
		if role and role not in roles:
			roles.append(role)
	if not roles:
		raise PolicyError("FRAPPE_2FA_ROLES names no roles")

	issuer = (env.get("FRAPPE_2FA_ISSUER") or "").strip() or DEFAULT_ISSUER

	return {"enabled": enabled == "1", "roles": roles, "issuer": issuer}


def desired_settings(policy):
	if not policy["enabled"]:
		return {"enable_two_factor_auth": 0}
	return {
		"enable_two_factor_auth": 1,
		"two_factor_method": "OTP App",
		"otp_issuer_name": policy["issuer"],
		"bypass_2fa_for_retricted_ip_users": 0,
		"login_with_email_link": 0,
	}


def _normalise(value, like):
	if isinstance(like, int):
		return int(value or 0)
	return value or ""


def _enforced_roles(frappe):
	return set(frappe.get_all("Role", filters={"two_factor_auth": 1}, pluck="name"))


def apply_policy(frappe, policy):
	"""Bring the site in line with the policy. Returns a list of the changes made."""
	wanted_roles = set(policy["roles"])
	if policy["enabled"]:
		if "Guest" in wanted_roles:
			raise PolicyError("FRAPPE_2FA_ROLES cannot include Guest, which never signs in")
		existing = set(frappe.get_all("Role", filters={"disabled": 0}, pluck="name"))
		missing = sorted(wanted_roles - existing)
		if missing:
			raise PolicyError(
				f"FRAPPE_2FA_ROLES names roles that do not exist or are disabled: {', '.join(missing)}"
			)

	settings = desired_settings(policy)
	changes = []
	for field, value in settings.items():
		current = frappe.db.get_single_value(SETTINGS_DOCTYPE, field)
		if _normalise(current, value) != value:
			frappe.db.set_single_value(SETTINGS_DOCTYPE, field, value)
			changes.append(f"{field}: {current!r} -> {value!r}")

	if policy["enabled"]:
		enforced = _enforced_roles(frappe)
		for role in sorted(wanted_roles - enforced):
			frappe.db.set_value("Role", role, "two_factor_auth", 1)
			changes.append(f"role {role}: 2FA on")
		for role in sorted(enforced - wanted_roles):
			frappe.db.set_value("Role", role, "two_factor_auth", 0)
			changes.append(f"role {role}: 2FA off")

	verify_policy(frappe, policy)
	return changes


def verify_policy(frappe, policy):
	for field, value in desired_settings(policy).items():
		current = frappe.db.get_single_value(SETTINGS_DOCTYPE, field)
		if _normalise(current, value) != value:
			raise PolicyError(f"read-back mismatch on {field}: expected {value!r}, found {current!r}")
	if policy["enabled"]:
		enforced = _enforced_roles(frappe)
		if enforced != set(policy["roles"]):
			raise PolicyError(
				f"read-back mismatch on 2FA roles: expected {sorted(policy['roles'])}, found {sorted(enforced)}"
			)


def main(argv):
	if len(argv) != 2:
		print("usage: configure_2fa.py <site>", file=sys.stderr)
		return 2

	try:
		policy = parse_env(os.environ)
	except PolicyError as e:
		print(f"2FA policy error: {e}", file=sys.stderr)
		return 1

	import frappe

	frappe.init(site=argv[1], sites_path=".")
	frappe.connect()
	try:
		changes = apply_policy(frappe, policy)
		# Standalone boot script, not a request or job: Frappe never auto-commits here, so the
		# policy is lost unless committed explicitly (rolled back below on any failure).
		frappe.db.commit()  # nosemgrep: frappe-semgrep-rules.rules.frappe-manual-commit
	except PolicyError as e:
		frappe.db.rollback()
		print(f"2FA policy error: {e}", file=sys.stderr)
		return 1
	except Exception:
		frappe.db.rollback()
		raise
	finally:
		frappe.destroy()

	state = f"enabled for roles: {', '.join(policy['roles'])}" if policy["enabled"] else "DISABLED"
	print(f"2FA policy applied — {state}; {len(changes)} change(s)")
	for change in changes:
		print(f"  {change}")
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv))
