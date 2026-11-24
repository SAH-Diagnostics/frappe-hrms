#!/usr/bin/env bash
#
# Tests for the site persistence steps in docker/init.sh: assert_site_mount and
# ensure_encryption_key.
#
# Ticket: VC-644 — every deploy lost the Frappe encryption_key and uploaded files.
#
# Why this file exists
# --------------------
# Every deploy runs `compose down && up`, and the bench (including sites/<site>) lived inside
# the container. site_config.json was rebuilt without an encryption_key, so Frappe generated
# a random one and every stored secret (2FA seeds, email passwords, API secrets) became
# undecryptable; uploaded files were discarded with the container.
#
# init.sh writes the pinned key from the deploy secret, and sites/<site> is the frappe-site-data
# volume mounted in place.
#
# Ticket: VC-776 — VC-644 first symlinked sites/<site> into the volume. Frappe's get_sites()
# skips symlinked sites, so from 25 Sep 2026 the scheduler ran nothing (no inbox fetch, no
# email queue, no HR jobs) and public files 404'd, with no error anywhere. The site must now be
# a real mount point; a symlink, a plain folder or a symlinked parent stops the boot.
#
# For the key, the dangerous direction is overwriting a key that already encrypts data, so a
# different key must stop the boot unless the site was created during it.
#
# The functions are extracted from init.sh and run against temp directories; `sudo` is
# stubbed. The wiring checks read init.sh itself. Nothing here touches a server or database.
#
# Run:  bash docker/__tests__/init-site-persistence.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SH="${INIT_SH:-$SCRIPT_DIR/../init.sh}"

passed=0
failed=0
pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Generated per run, so no key-shaped literal lives in the repository (the secret scan flags one).
new_key() { python3 -c "import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"; }
KEY="$(new_key)"
OTHER_KEY="$(new_key)"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
STUB
chmod +x "$WORK/bin/sudo"

sed -n '/^assert_site_mount() {/,/^}/p' "$INIT_SH" > "$WORK/assert_site_mount.sh"
sed -n '/^ensure_encryption_key() {/,/^}/p' "$INIT_SH" > "$WORK/ensure_encryption_key.sh"
sed -n '/^ensure_site_dirs() {/,/^}/p' "$INIT_SH" > "$WORK/ensure_site_dirs.sh"

echo "Testing site persistence in: $INIT_SH"
echo

echo "T0: the functions exist in init.sh"
check "assert_site_mount extracted" 1 "$(grep -c '^assert_site_mount() {' "$WORK/assert_site_mount.sh")"
check "ensure_encryption_key extracted" 1 "$(grep -c '^ensure_encryption_key() {' "$WORK/ensure_encryption_key.sh")"
echo

# $1 = scenario dir, $2 = key (env), $3 = mode; site_config at $1/bench/sites/site.test/.
run_ensure() {
    (
        cd "$1" || exit 1
        BENCH_DIR="$1/bench" SITE_NAME="site.test" ENCRYPTION_KEY="$2" PATH="$WORK/bin:$PATH" \
            bash -c ". '$WORK/ensure_encryption_key.sh'; ensure_encryption_key '$3'" \
            > "$1/stdout" 2> "$1/stderr"
        echo $? > "$1/status"
    )
}
new_config() { # $1 = scenario dir, $2 = JSON body
    mkdir -p "$1/bench/sites/site.test"
    printf '%s\n' "$2" > "$1/bench/sites/site.test/site_config.json"
    chmod 640 "$1/bench/sites/site.test/site_config.json"
}
key_in() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('encryption_key',''))" "$1"; }
leaks() { cat "$1/stdout" "$1/stderr" | grep -c -F -e "$KEY" -e "$OTHER_KEY"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

echo "T1: a config with no key gets the pinned key, and keeps everything else"
S="$WORK/t1"; new_config "$S" '{"db_name": "erp", "db_password": "p"}'
run_ensure "$S" "$KEY" strict
CFG="$S/bench/sites/site.test/site_config.json"
check "exited 0" 0 "$(cat "$S/status")"
check "key written" "$KEY" "$(key_in "$CFG")"
check "db_name kept" erp "$(python3 -c "import json;print(json.load(open('$CFG'))['db_name'])")"
check "file mode kept (640)" 640 "$(mode_of "$CFG")"
check "key not printed" 0 "$(leaks "$S")"
echo

echo "T2: the same key is left alone"
S="$WORK/t2"; new_config "$S" "{\"db_name\": \"erp\", \"encryption_key\": \"$KEY\"}"
before="$(cat "$S/bench/sites/site.test/site_config.json")"
run_ensure "$S" "$KEY" strict
check "exited 0" 0 "$(cat "$S/status")"
check "file unchanged" "$before" "$(cat "$S/bench/sites/site.test/site_config.json")"
check "reported a match" 1 "$(grep -c 'matches the deploy secret' "$S/stdout")"
echo

echo "T3: a different key stops the boot and is never overwritten (strict)"
S="$WORK/t3"; new_config "$S" "{\"encryption_key\": \"$OTHER_KEY\"}"
run_ensure "$S" "$KEY" strict
check "exited 1" 1 "$(cat "$S/status")"
check "FATAL on stderr" 1 "$(grep -c 'FATAL: site_config.json holds a different encryption_key' "$S/stderr")"
check "existing key kept" "$OTHER_KEY" "$(key_in "$S/bench/sites/site.test/site_config.json")"
check "neither key printed" 0 "$(leaks "$S")"
echo

echo "T4: a site created during this boot adopts the pinned key (adopt)"
S="$WORK/t4"; new_config "$S" "{\"encryption_key\": \"$OTHER_KEY\"}"
run_ensure "$S" "$KEY" adopt
check "exited 0" 0 "$(cat "$S/status")"
check "key replaced" "$KEY" "$(key_in "$S/bench/sites/site.test/site_config.json")"
check "neither key printed" 0 "$(leaks "$S")"
echo

echo "T5: a malformed or missing key stops the boot"
for bad in "" "too-short" "${KEY%=}" "${KEY%=}!"; do
    S="$WORK/t5-${#bad}"; new_config "$S" '{"db_name": "erp"}'
    run_ensure "$S" "$bad" strict
    check "key of length ${#bad}: exited 1" 1 "$(cat "$S/status")"
    check "key of length ${#bad}: reported as not a Fernet key" 1 "$(grep -c 'is not a Fernet key' "$S/stderr")"
    check "key of length ${#bad}: config untouched" "" "$(key_in "$S/bench/sites/site.test/site_config.json")"
done
echo

echo "T6: an unreadable config stops the boot"
S="$WORK/t6a"; mkdir -p "$S/bench/sites/site.test"
run_ensure "$S" "$KEY" strict
check "missing config: exited 1" 1 "$(cat "$S/status")"
check "missing config: FATAL" 1 "$(grep -c 'FATAL: could not read' "$S/stderr")"
S="$WORK/t6b"; new_config "$S" '{not json'
run_ensure "$S" "$KEY" strict
check "corrupt config: exited 1" 1 "$(cat "$S/status")"
check "corrupt config: file untouched" '{not json' "$(cat "$S/bench/sites/site.test/site_config.json")"
echo

# $1 = scenario dir; bench at $1/bench, mountinfo at $1/mountinfo (absent = no mounts).
run_assert() {
    [ -f "$1/mountinfo" ] || : > "$1/mountinfo"
    BENCH_DIR="$1/bench" SITE_NAME="site.test" MOUNTINFO="$1/mountinfo" PATH="$WORK/bin:$PATH" \
        bash -c "set -e; . '$WORK/assert_site_mount.sh'; assert_site_mount" > "$1/stdout" 2> "$1/stderr"
    echo $? > "$1/status"
}
mount_at() { # $1 = scenario dir, $2 = mount point; a mountinfo line shaped like the kernel's
    echo "1234 1200 0:52 /volumes/frappe-site-data/_data/site.test $2 rw,relatime - ext4 /dev/root rw" >> "$1/mountinfo"
}
new_scenario() { mkdir -p "$1"; (cd "$1" && pwd -P); } # physical path: macOS /var is a symlink

echo "T7: the site folder mounted from the volume boots, and a second boot is a no-op"
S="$(new_scenario "$WORK/t7")"; mkdir -p "$S/bench/sites/site.test"
mount_at "$S" "$S/bench/sites/site.test"
run_assert "$S"
check "exited 0" 0 "$(cat "$S/status")"
check "reports the mounted volume" 1 "$(grep -c 'frappe-site-data volume' "$S/stdout")"
run_assert "$S"
check "second boot exited 0" 0 "$(cat "$S/status")"
check "nothing turned into a symlink" no "$([ -L "$S/bench/sites/site.test" ] && echo yes || echo no)"
echo

echo "T8: a symlinked site stops the boot (Frappe's scheduler skips symlinked sites)"
S="$(new_scenario "$WORK/t8")"; mkdir -p "$S/bench/sites" "$S/site-data/site.test"
ln -s "$S/site-data/site.test" "$S/bench/sites/site.test"
mount_at "$S" "$S/bench/sites/site.test"
run_assert "$S"
check "exited 1" 1 "$(cat "$S/status")"
check "FATAL names the symlink and why" 1 "$(grep -c "is a symlink. Frappe's scheduler ignores symlinked sites" "$S/stderr")"
check "the link is left in place" "$S/site-data/site.test" "$(readlink "$S/bench/sites/site.test")"
echo

echo "T9: a plain folder that is not a mount stops the boot (the next deploy would discard it)"
S="$(new_scenario "$WORK/t9")"; mkdir -p "$S/bench/sites/site.test"
mount_at "$S" "$S/bench/sites/other.site"
run_assert "$S"
check "exited 1" 1 "$(cat "$S/status")"
check "FATAL names the missing mount" 1 "$(grep -c 'is not a mount point' "$S/stderr")"
echo

echo "T10: a missing site folder, or one reached through a symlinked parent, stops the boot"
S="$(new_scenario "$WORK/t10")"; mkdir -p "$S/bench/sites"
run_assert "$S"
check "missing: exited 1" 1 "$(cat "$S/status")"
check "missing: FATAL" 1 "$(grep -c 'FATAL: .* is missing' "$S/stderr")"
S="$(new_scenario "$WORK/t10b")"; mkdir -p "$S/real-sites/site.test" "$S/bench"
ln -s "$S/real-sites" "$S/bench/sites"
mount_at "$S" "$S/bench/sites/site.test"
run_assert "$S"
check "symlinked parent: exited 1" 1 "$(cat "$S/status")"
check "symlinked parent: FATAL" 1 "$(grep -c 'a parent folder is a symlink' "$S/stderr")"
echo

# ---------------------------------------------------------------------------
echo "T11: init.sh wires both steps in before anything can encrypt"
line_of() { grep -n -F -- "$1" "$INIT_SH" | head -1 | cut -d: -f1; }
all_lines() { grep -n -F -- "$1" "$INIT_SH" | cut -d: -f1; }
bench_init=$(line_of 'bench init --ignore-exist')
assert_call=$(grep -n '^assert_site_mount$' "$INIT_SH" | head -1 | cut -d: -f1)
first_site_cmd=$(line_of 'bench --site "$SITE_NAME"')
if [ -n "$assert_call" ] && [ -n "$bench_init" ] && [ "$assert_call" -gt "$bench_init" ] && [ "$assert_call" -lt "$first_site_cmd" ]; then
    pass "assert_site_mount runs after bench init and before the first site command"
else
    fail "assert_site_mount is not between bench init ($bench_init) and the first site command ($first_site_cmd): '$assert_call'"
fi
# Docker creates $BENCH_DIR for the mount, so a guard on the folder would skip bench init forever.
check "bench init is guarded on the frappe app, not the bench folder" 1 \
    "$(grep -cxF 'if [ ! -d "$BENCH_DIR/apps/frappe" ]; then' "$INIT_SH")"
check "no guard on the bench folder itself" 0 "$(grep -cF 'if [ ! -d "$BENCH_DIR" ]' "$INIT_SH")"
init_cmd="$(grep -E '^[[:space:]]+bench init ' "$INIT_SH")"
check "exactly one bench init command" 1 "$(grep -c . <<< "$init_cmd")"
check "bench init populates the existing folder (--ignore-exist)" 1 "$(grep -c -- '--ignore-exist' <<< "$init_cmd")"
# A failed init asks "rollback?" and then rmtree's the bench, mounted site included.
check "bench init reads no stdin, so its rollback prompt cannot delete the mounted site" 1 \
    "$(grep -cE '< /dev/null[[:space:]]*$' <<< "$init_cmd")"
# Otherwise a 6-hourly bench backup writes site_config backups (key, db password) for the S3 push.
check "bench init installs no backup crontab (--no-backups)" 1 "$(grep -c -- '--no-backups' <<< "$init_cmd")"
chown_line=$(grep -n 'sudo chown frappe:frappe "$BENCH_DIR" "$BENCH_DIR/sites"' "$INIT_SH" | head -1 | cut -d: -f1)
if [ -n "$chown_line" ] && [ "$chown_line" -lt "$bench_init" ]; then
    pass "the root-owned folders Docker created are handed to frappe before bench init"
else
    fail "no chown of \$BENCH_DIR and sites before bench init ('$chown_line', init $bench_init)"
fi
check "init.sh never symlinks the site" 0 "$(grep -v '^[[:space:]]*#' "$INIT_SH" | grep -c 'ln -s')"
check "the boot-time chown skips the mounted site folder" 2 \
    "$(grep -cF -- '-path "$BENCH_DIR/sites/$SITE_NAME" -prune' "$INIT_SH")"
check "no recursive chown/chmod walks the whole bench" 0 "$(grep -cE '^(chown|chmod) -R .*frappe-bench' "$INIT_SH")"
pre_block=$(grep -n -A2 'if \[ -f "$BENCH_DIR/sites/$SITE_NAME/site_config.json" \]; then' "$INIT_SH" \
    | grep 'ensure_encryption_key strict' | head -1 | cut -d- -f1)
first_migrate=$(all_lines 'bench --site "$SITE_NAME" migrate' | head -1)
if [ -n "$pre_block" ] && [ "$pre_block" -lt "$first_migrate" ]; then
    pass "a site already on the volume gets the key before the first migrate"
else
    fail "no key check before the first migrate (check: '$pre_block', migrate: $first_migrate)"
fi
# Each site_config.json the script writes is followed by the key before the next bench command.
for eof in $(grep -n '^EOF$' "$INIT_SH" | cut -d: -f1); do
    if sed -n "$((eof + 1)),$((eof + 3))p" "$INIT_SH" | grep -q 'ensure_encryption_key strict'; then
        pass "the site_config.json written before line $eof gets the key immediately"
    else
        fail "the site_config.json written before line $eof is not followed by ensure_encryption_key"
    fi
done
post=$(grep -n '^    ensure_encryption_key adopt$' "$INIT_SH" | head -1 | cut -d: -f1)
host_name=$(line_of 'set-config host_name')
if [ -n "$post" ] && [ "$post" -lt "$host_name" ]; then
    pass "after site setup, the key is asserted (adopt only for a site created this boot)"
else
    fail "no final key assertion before host_name is set"
fi
check "every bench new-site path marks SITE_CREATED" 2 "$(grep -c '^ *SITE_CREATED=true$' "$INIT_SH")"
check "ENCRYPTION_KEY is required at the top of init.sh" 1 \
    "$(grep -c '^: "${ENCRYPTION_KEY:?' "$INIT_SH")"
echo

echo "T12: the site's files folders exist on every boot, including an attached site"
# Staging, 2026-09-25: the RDS attach path made bare private/ and public/, and every upload
# failed with FileNotFoundError on ./<site>/private/files/<name>.
check "ensure_site_dirs extracted" 1 "$(grep -c '^ensure_site_dirs() {' "$WORK/ensure_site_dirs.sh")"
S="$WORK/t12"; mkdir -p "$S/bench/sites/site.test/private" "$S/bench/sites/site.test/public/files"
echo keep > "$S/bench/sites/site.test/public/files/existing.png"
run_dirs() { bash -c "set -e; BENCH_DIR='$S/bench'; SITE_NAME=site.test; source '$WORK/ensure_site_dirs.sh'; ensure_site_dirs"; echo $?; }
check "exited 0" 0 "$(run_dirs)"
for d in public/files private/files private/backups locks logs; do
    check "$d exists" yes "$([ -d "$S/bench/sites/site.test/$d" ] && echo yes || echo no)"
done
check "an existing file is left alone" keep "$(cat "$S/bench/sites/site.test/public/files/existing.png")"
check "a second run is a no-op" 0 "$(run_dirs)"
call=$(grep -n '^ensure_site_dirs$' "$INIT_SH" | head -1 | cut -d: -f1)
final_key=$(grep -n '^    ensure_encryption_key adopt$' "$INIT_SH" | head -1 | cut -d: -f1)
bench_start=$(grep -n '^bench start$' "$INIT_SH" | head -1 | cut -d: -f1)
if [ -n "$call" ] && [ -n "$final_key" ] && [ -n "$bench_start" ] && [ "$final_key" -lt "$call" ] && [ "$call" -lt "$bench_start" ]; then
    pass "called after every site setup path ($final_key) and before the server starts ($bench_start)"
else
    fail "ensure_site_dirs call ($call) is not between site setup ($final_key) and bench start ($bench_start)"
fi
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
