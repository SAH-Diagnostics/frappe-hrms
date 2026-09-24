#!/usr/bin/env node
/**
 * check-app-advisories.mjs -- VC-648 (14-day ERP patch and dependency process)
 *
 * Answers one question: are the frappe/erpnext/hrms versions pinned in docker/init.sh carrying
 * any published high or critical advisory, and if so, is it past the 14-day standard?
 *
 * Dependabot cannot answer it. The deployed application versions are not in a manifest Dependabot
 * parses -- they are shell variables consumed by `bench get-app --branch <tag>`, resolved against
 * upstream at build time. Every one of the 20 open high/critical advisories found on 2026-09-23
 * sat in exactly that blind spot, two of them 27 days past the standard.
 *
 * Usage:
 *   node .github/scripts/check-app-advisories.mjs [--json] [--sla-days 14] [--init path]
 *
 * Exit codes -- distinct on purpose, because "found nothing" and "could not look" must never
 * produce the same result. A check that fails open is worse than no check: it reports success on
 * the day the network breaks, and nobody re-reads a green job.
 *   0  checked successfully, no high/critical advisory affects the pinned versions
 *   1  at least one high/critical advisory affects a pinned version
 *   2  the check could not be performed (no pins, unparseable version, API failure, empty feed)
 *
 * Offline testing: set ADVISORY_FIXTURE_DIR to a directory holding <owner>-<repo>.json files and
 * no network call is made. The source in use is always printed, so a fixture run can never be
 * mistaken for a live one.
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Exit 1 means "findings", and the workflow renders it as "a high or critical advisory affects a
 * pinned version". Node's default exit code for an uncaught throw is ALSO 1, so without these two
 * handlers a DNS failure or a malformed API response is reported to the reader as a security
 * finding. That is the contract in the header inverting itself on the two failure paths most
 * likely to actually happen.
 */
process.on('unhandledRejection', (e) => fail(`unhandled rejection: ${e instanceof Error ? e.message : String(e)}`));
process.on('uncaughtException', (e) => fail(`uncaught exception: ${e instanceof Error ? e.message : String(e)}`));

const REPOS = [
  { app: 'frappe', owner: 'frappe', repo: 'frappe', pin: 'FRAPPE_REF' },
  { app: 'erpnext', owner: 'frappe', repo: 'erpnext', pin: 'ERPNEXT_REF' },
  { app: 'hrms', owner: 'frappe', repo: 'hrms', pin: 'HRMS_REF' },
];

const BLOCKING_SEVERITIES = new Set(['high', 'critical']);

// --- arguments ------------------------------------------------------------
const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const slaDays = parseSlaDays(argValue('--sla-days'));
function parseSlaDays(raw) {
  if (raw === undefined) return 14;
  // `Number('')` is 0, not NaN, so an empty value would silently mean "everything is overdue"
  // rather than being rejected. Reject blank explicitly before coercing.
  if (String(raw).trim() === '') fail('--sla-days was given an empty value');
  const n = Number(raw);
  // `Number('abc')` is NaN, and NaN silently DISABLES the standard: every `overdueBy` becomes
  // NaN, nothing compares greater than zero, and the report cheerfully states "0 past the
  // NaN-day standard" while still exiting 1. The workflow takes this as free text from a
  // workflow_dispatch input, so "14 days" typed by a human reaches here.
  if (!Number.isFinite(n) || n < 0) fail(`--sla-days must be a non-negative number, got '${raw}'`);
  return n;
}
const initPath = argValue('--init') ?? 'docker/init.sh';

function argValue(flag) {
  const i = argv.indexOf(flag);
  return i === -1 || i === argv.length - 1 ? undefined : argv[i + 1];
}

// --- semver ---------------------------------------------------------------
/**
 * The comparison this file exists to get right.
 *
 * A string compare says "16.9.0" > "16.35.0", because '9' > '3' at the fourth character. That is
 * the single most dangerous bug this checker could have: it silently reports a badly out-of-date
 * pin as clean, and it only misfires on exactly the versions that are furthest behind. Compare
 * numerically, segment by segment, or do not compare at all.
 */
function parseVersion(raw) {
  // ANCHORED at both ends, deliberately. An unanchored regex silently truncates a suffix, so
  // `v16.35.0-beta.1` parsed to [16,35,0] -- equal to the release that FIXES an advisory -- and
  // the beta, which predates the fix and is vulnerable, was reported clean. Frappe ships
  // `-beta` tags, so that is a reachable pin value, and it is the same false-negative class the
  // numeric-comparison note below exists to prevent. `16.35.0.1` lost its fourth segment the
  // same way. Returning null sends both to the "cannot compare" path, which is the honest answer.
  const m = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(String(raw).trim());
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

function compareVersions(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

/**
 * GitHub writes ranges as a comma-separated conjunction: ">= 16.0.0, < 16.35.0", "< 16.31.0".
 * Every clause must hold. An unrecognised clause returns null rather than false -- an unparsed
 * range must escalate, not quietly decide the version is safe.
 */
function versionInRange(version, range) {
  if (!range || typeof range !== 'string') return null;
  for (const clauseRaw of range.split(',')) {
    const clause = clauseRaw.trim();
    if (!clause) continue;
    // The operator is OPTIONAL: GitHub writes an exact-version range as a bare `16.11.0`, and
    // that form is live in the frappe and hrms feeds today. Requiring an operator turned every
    // one of them into an unparseable range, which this function escalates -- so a pin that is
    // obviously unaffected was reported as a finding.
    const m = /^(>=|<=|>|<|=)?\s*(.+)$/.exec(clause);
    if (!m) return null;
    const op = m[1] ?? '=';
    const bound = parseVersion(m[2]);
    if (!bound) return null; // e.g. the literal "tbd", which the live feed does contain
    const cmp = compareVersions(version, bound);
    const ok =
      op === '<' ? cmp < 0
      : op === '<=' ? cmp <= 0
      : op === '>' ? cmp > 0
      : op === '>=' ? cmp >= 0
      : cmp === 0;
    if (!ok) return false;
  }
  return true;
}

// --- pins -----------------------------------------------------------------
function readPins(path) {
  if (!existsSync(path)) fail(`cannot read pins: ${path} does not exist`);
  const src = readFileSync(path, 'utf8');
  const pins = {};
  for (const { pin } of REPOS) {
    // Tolerates leading whitespace, an `export` prefix and the `:=` form. It is still tighter
    // than shell's real grammar, which is why it fails CLOSED below rather than guessing.
    const m = new RegExp(`^[ \t]*(?:export[ \t]+)?${pin}="?\\$\\{${pin}:[-=]([^}"]*)\\}"?`, 'm').exec(src);
    if (m) pins[pin] = m[1].trim();
  }
  const missing = REPOS.filter((r) => !pins[r.pin]).map((r) => r.pin);
  if (missing.length) {
    // Not a warning. If the pins are gone, the apps are being cloned from a moving branch again
    // and the deployed version is whatever upstream shipped that morning -- unknowable, so
    // uncheckable, so unevidenceable against a 14-day standard.
    // Two very different causes, and the message must not assert the alarming one. Either the
    // pins were removed -- in which case the apps are tracking a moving branch again and the
    // deployed version is whatever upstream shipped that morning -- or the file was merely
    // reformatted past what this reader understands. Both are exit 2; only one is an incident.
    fail(
      `no pin found for ${missing.join(', ')} in ${path}. ` +
        'Either the pins were removed, in which case the apps are tracking a moving branch again ' +
        'and the deployed version is unknowable, or the assignment was reformatted past what this ' +
        'reader accepts. Check the file before assuming the second.'
    );
  }
  return pins;
}

// --- advisory source ------------------------------------------------------
async function fetchAdvisories({ owner, repo }) {
  const fixtureDir = process.env.ADVISORY_FIXTURE_DIR;
  if (fixtureDir) {
    if (process.env.GITHUB_ACTIONS && !process.env.ALLOW_FIXTURES_IN_CI) {
      // Defence in depth. Nothing wires the self-test's fixture directory into the live step
      // today, but a repository- or organisation-level Actions `env` of this name would turn the
      // live check into a fixture replay that still exits 0 and still prints "No high or critical
      // advisory affects the pinned versions".
      fail('ADVISORY_FIXTURE_DIR is set under GITHUB_ACTIONS; refusing to replay fixtures as a live check');
    }
    const file = join(fixtureDir, `${owner}-${repo}.json`);
    if (!existsSync(file)) fail(`fixture mode: ${file} not found`);
    let fixture;
    try {
      fixture = JSON.parse(readFileSync(file, 'utf8'));
    } catch (err) {
      fail(`fixture ${file} is not valid JSON: ${err.message}`);
    }
    if (!Array.isArray(fixture)) fail(`fixture ${file} is not an array`);
    // Deliberately routed through the same liveness assertion as the live path. An early return
    // here would exempt fixture mode from the guard -- and, worse, would make the guard
    // untestable by the hermetic suite, which is the only place it is ever exercised.
    return assertLive(fixture, owner, repo);
  }

  const out = [];
  const headers = { accept: 'application/vnd.github+json', 'user-agent': 'sah-vc648-advisory-check' };
  if (process.env.GITHUB_TOKEN) headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

  /**
   * CURSOR pagination, not `?page=N`.
   *
   * This endpoint ignores `page` completely: `?page=1` and `?page=2` return the identical rows.
   * An index-driven loop therefore refetched the same first 100 advisories on every iteration --
   * inflating the count tenfold, duplicating every finding tenfold -- and never fetched advisory
   * 101 at all. frappe is at 83 today and erpnext at 89, so this was a silent miss waiting on the
   * next dozen publications. The cursor lives in the `Link: <...>; rel="next"` header.
   */
  let url = `https://api.github.com/repos/${owner}/${repo}/security-advisories?per_page=100`;
  for (let hop = 0; hop < 20 && url; hop++) {
    let res;
    try {
      res = await fetch(url, { headers });
    } catch (err) {
      // A network failure is "could not look", never "looked and found nothing".
      fail(`network failure fetching advisories for ${owner}/${repo}: ${err.message}`);
    }
    if (!res.ok) fail(`GitHub API ${res.status} for ${owner}/${repo}: ${(await res.text().catch(() => '')).slice(0, 300)}`);

    let batch;
    try {
      batch = await res.json();
    } catch (err) {
      fail(`unreadable JSON from ${owner}/${repo}: ${err.message}`);
    }
    if (!Array.isArray(batch)) fail(`unexpected API payload for ${owner}/${repo}`);
    out.push(...batch);

    const next = /<([^>]+)>;\s*rel="next"/.exec(res.headers.get('link') ?? '');
    url = next ? next[1] : null;
  }

  return assertLive(out, owner, repo);
}

/**
 * Liveness, per repository rather than across all three.
 *
 * The guard used to test the SUM, so one dead feed hid behind two live ones: frappe returning an
 * empty array while erpnext returned anything at all produced "No high or critical advisory
 * affects the pinned versions", exit 0, with frappe -- the largest of the three surfaces, and the
 * one carrying the auth and permission layer -- never actually checked. All three repositories
 * have published advisories, so zero from any single one of them is a broken query.
 */
function assertLive(advisories, owner, repo) {
  if (advisories.length === 0) {
    fail(`${owner}/${repo} returned zero advisories; treating as a broken query, not a clean result`);
  }
  return advisories;
}

// --- evaluation -----------------------------------------------------------
function evaluate(app, pinnedRaw, advisories) {
  const version = parseVersion(pinnedRaw);
  if (!version) fail(`${app}: pinned ref '${pinnedRaw}' is not a version this checker can compare`);

  const findings = [];
  const seen = new Set(); // one finding per advisory, enforced rather than assumed
  for (const adv of advisories) {
    if (adv.state && adv.state !== 'published') continue;
    const severity = String(adv.severity ?? '').toLowerCase();
    if (!BLOCKING_SEVERITIES.has(severity)) continue;

    for (const vuln of adv.vulnerabilities ?? []) {
      // Only entries for the app being evaluated. Without this the first entry of a multi-package
      // advisory won -- which cannot MISS an advisory (a non-match continues) but does report
      // the wrong affected range and the wrong patched version, and those two fields are exactly
      // what a human reads to choose the upgrade target. Name-less entries are kept: the live
      // feed contains entries with `{"ecosystem":"","name":""}`, and dropping those WOULD lose
      // advisories. Case-insensitive: the feed contains both `Frappe` and `frappe`.
      const pkg = vuln.package?.name;
      if (pkg && pkg.toLowerCase() !== app.toLowerCase()) continue;
      const inRange = versionInRange(version, vuln.vulnerable_version_range);
      if (inRange === false) continue;
      if (seen.has(adv.ghsa_id)) continue;
      if (inRange === null) {
        // Escalate rather than skip: an unparsed range is an unknown, and an unknown in a
        // security check is a finding about the check.
        seen.add(adv.ghsa_id);
        findings.push({
          app, ghsa: adv.ghsa_id, severity, published: adv.published_at,
          summary: adv.summary, range: vuln.vulnerable_version_range,
          patched: vuln.patched_versions ?? null, unparsedRange: true, ageDays: null, overdueBy: null,
        });
        continue;
      }
      const publishedMs = adv.published_at ? Date.parse(adv.published_at) : NaN;
      const ageDays = Number.isFinite(publishedMs)
        ? Math.floor((Date.now() - publishedMs) / 86_400_000)
        : null; // an unparseable date must read as "unknown age", not print as "NaNd remaining"
      seen.add(adv.ghsa_id);
      findings.push({
        app, ghsa: adv.ghsa_id, severity, published: adv.published_at,
        summary: adv.summary, range: vuln.vulnerable_version_range,
        patched: vuln.patched_versions ?? null, unparsedRange: false,
        ageDays, overdueBy: ageDays === null ? null : ageDays - slaDays,
      });
      // No `break` here. It would be a second mechanism doing the same job as the `seen` guard
      // above, and two overlapping guards mean either can be deleted without any test noticing.
      // One enforced rule, one test. Subsequent entries for this advisory fall out at `seen`.
    }
  }
  return findings;
}

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(2);
}

// --- main -----------------------------------------------------------------
const pins = readPins(initPath);
const usingFixtures = Boolean(process.env.ADVISORY_FIXTURE_DIR);
if (!asJson) {
  console.log(`Advisory source: ${usingFixtures ? `FIXTURES (${process.env.ADVISORY_FIXTURE_DIR}) -- NOT a live check` : 'GitHub Advisory API (live)'}`);
  console.log(`SLA: ${slaDays} days   Pins from: ${initPath}\n`);
}

let totalAdvisoriesSeen = 0;
const findings = [];
for (const r of REPOS) {
  const advisories = await fetchAdvisories(r);
  totalAdvisoriesSeen += advisories.length;
  findings.push(...evaluate(r.app, pins[r.pin], advisories));
}

// Liveness is asserted per repository inside fetchAdvisories(), which is strictly stronger than
// the sum: a single dead feed can no longer hide behind two live ones.

const overdue = findings.filter((f) => (f.overdueBy ?? 0) > 0);
const rank = { critical: 0, high: 1 };
findings.sort((a, b) => (rank[a.severity] - rank[b.severity]) || (b.ageDays ?? 0) - (a.ageDays ?? 0));

if (asJson) {
  console.log(JSON.stringify({
    source: usingFixtures ? 'fixtures' : 'live',
    slaDays, pins, advisoriesSeen: totalAdvisoriesSeen,
    findingCount: findings.length, overdueCount: overdue.length, findings,
  }, null, 2));
} else {
  console.log(`Checked ${totalAdvisoriesSeen} published advisories across frappe, erpnext and hrms.`);
  for (const { app, pin } of REPOS.map((r) => ({ app: r.app, pin: r.pin }))) {
    console.log(`  ${app.padEnd(8)} ${pins[pin]}`);
  }
  console.log();
  if (findings.length === 0) {
    console.log('No high or critical advisory affects the pinned versions.');
  } else {
    console.log(`${findings.length} high/critical advisor${findings.length === 1 ? 'y' : 'ies'} affect the pinned versions; ${overdue.length} past the ${slaDays}-day standard.\n`);
    for (const f of findings) {
      const sla = f.overdueBy === null ? 'unknown age'
        : f.overdueBy > 0 ? `OVERDUE by ${f.overdueBy}d`
        : `${-f.overdueBy}d remaining`;
      console.log(`  [${f.severity.toUpperCase()}] ${f.app} ${f.ghsa}  published ${String(f.published).slice(0, 10)}  ${sla}`);
      console.log(`      affects ${f.range}${f.patched ? `  ->  fixed in ${f.patched}` : ''}`);
      if (f.unparsedRange) console.log('      NOTE: range could not be parsed; reported as a finding rather than skipped');
      if (f.summary) console.log(`      ${String(f.summary).split('\n')[0].slice(0, 160)}`);
    }
  }
}

process.exit(findings.length > 0 ? 1 : 0);
