#!/usr/bin/env bash
#
# Tests for the site persistence steps in docker/init.sh: link_site_dir and
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
# init.sh now links sites/<site> into the frappe-site-data volume and writes the pinned key
# from the deploy secret. The dangerous direction is overwriting a key that already encrypts
# data, so a different key must stop the boot unless the site was created during it.
#
# The two functions are extracted from init.sh and run against temp directories; `sudo` is
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

sed -n '/^link_site_dir() {/,/^}/p' "$INIT_SH" > "$WORK/link_site_dir.sh"
sed -n '/^ensure_encryption_key() {/,/^}/p' "$INIT_SH" > "$WORK/ensure_encryption_key.sh"
sed -n '/^ensure_site_dirs() {/,/^}/p' "$INIT_SH" > "$WORK/ensure_site_dirs.sh"

echo "Testing site persistence in: $INIT_SH"
echo

echo "T0: the functions exist in init.sh"
check "link_site_dir extracted" 1 "$(grep -c '^link_site_dir() {' "$WORK/link_site_dir.sh")"
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

# $1 = scenario dir; bench at $1/bench, volume at $1/site-data.
run_link() {
    BENCH_DIR="$1/bench" SITE_NAME="site.test" SITE_DATA_DIR="$1/site-data" PATH="$WORK/bin:$PATH" \
        bash -c "set -e; . '$WORK/link_site_dir.sh'; link_site_dir" > "$1/stdout" 2> "$1/stderr"
    echo $? > "$1/status"
}

echo "T7: without the volume the boot stops"
S="$WORK/t7"; mkdir -p "$S/bench/sites"
run_link "$S"
check "exited 1" 1 "$(cat "$S/status")"
check "FATAL names the missing volume" 1 "$(grep -c 'volume is not mounted' "$S/stderr")"
echo

echo "T8: a fresh bench is linked into the volume, and a second boot is a no-op"
S="$WORK/t8"; mkdir -p "$S/bench/sites" "$S/site-data"
run_link "$S"
check "first boot exited 0" 0 "$(cat "$S/status")"
check "site dir is a symlink to the volume" "$S/site-data/site.test" "$(readlink "$S/bench/sites/site.test")"
run_link "$S"
check "second boot exited 0" 0 "$(cat "$S/status")"
check "still linked to the volume" "$S/site-data/site.test" "$(readlink "$S/bench/sites/site.test")"
echo

echo "T9: files already in the bench move into an empty volume"
S="$WORK/t9"; mkdir -p "$S/bench/sites/site.test/private/files" "$S/site-data"
echo data > "$S/bench/sites/site.test/private/files/a.pdf"
run_link "$S"
check "exited 0" 0 "$(cat "$S/status")"
check "file now on the volume" data "$(cat "$S/site-data/site.test/private/files/a.pdf" 2>/dev/null)"
check "file reachable through the link" data "$(cat "$S/bench/sites/site.test/private/files/a.pdf" 2>/dev/null)"
echo

echo "T10: conflicting site data stops the boot and nothing is removed"
S="$WORK/t10"; mkdir -p "$S/bench/sites/site.test" "$S/site-data/site.test"
echo bench > "$S/bench/sites/site.test/x"; echo volume > "$S/site-data/site.test/x"
run_link "$S"
check "exited 1" 1 "$(cat "$S/status")"
check "bench copy kept" bench "$(cat "$S/bench/sites/site.test/x")"
check "volume copy kept" volume "$(cat "$S/site-data/site.test/x")"
S="$WORK/t10b"; mkdir -p "$S/bench/sites" "$S/site-data" "$S/elsewhere"
ln -s "$S/elsewhere" "$S/bench/sites/site.test"
run_link "$S"
check "a link to the wrong place: exited 1" 1 "$(cat "$S/status")"
echo

# ---------------------------------------------------------------------------
echo "T11: init.sh wires both steps in before anything can encrypt"
line_of() { grep -n -F -- "$1" "$INIT_SH" | head -1 | cut -d: -f1; }
all_lines() { grep -n -F -- "$1" "$INIT_SH" | cut -d: -f1; }
bench_init=$(line_of 'bench init --skip-redis-config-generation')
link_call=$(grep -n '^link_site_dir$' "$INIT_SH" | head -1 | cut -d: -f1)
first_site_cmd=$(line_of 'bench --site "$SITE_NAME"')
if [ -n "$link_call" ] && [ "$link_call" -gt "$bench_init" ] && [ "$link_call" -lt "$first_site_cmd" ]; then
    pass "link_site_dir runs after bench init and before the first site command"
else
    fail "link_site_dir is not between bench init ($bench_init) and the first site command ($first_site_cmd): '$link_call'"
fi
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
