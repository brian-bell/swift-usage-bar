#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
wrapper="$repo_root/scripts/claude-statusline-cache"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/ccstatusline" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_STATUSLINE_ARGS_FILE"
if [ "${FAKE_STATUSLINE_FAIL:-}" = "1" ]; then
    cat
    printf 'synthetic statusline failure\n' >&2
    exit 17
fi
cat
SH
chmod 755 "$fake_bin/ccstatusline"

input_file="$repo_root/Tests/Fixtures/claude-statusline.json"
file_mode() {
    if stat -f '%Lp' "$1" 2>/dev/null; then
        return
    fi
    stat -c '%a' "$1"
}

assert_no_temp_files() {
    cache_dir="$(dirname "$1")"
    cache_base="$(basename "$1")"
    if find "$cache_dir" -name "${cache_base}.input.*" -o -name "${cache_base}.tmp.*" | grep -q .; then
        printf 'expected wrapper temp files to be cleaned up under %s\n' "$cache_dir" >&2
        find "$cache_dir" -maxdepth 1 -type f >&2
        exit 1
    fi
}

run_wrapper() {
    actual_stdout="$1"
    actual_stderr="$2"
    args_file="$3"
    cache_file="$4"
    shift 4

    set +e
    PATH="$fake_bin:$PATH" \
        AI_USAGE_BAR_CLAUDE_STATUS_JSON="$cache_file" \
        FAKE_STATUSLINE_ARGS_FILE="$args_file" \
        "$@" \
        "$wrapper" --theme compact <"$input_file" >"$actual_stdout" 2>"$actual_stderr"
    status=$?
    set -e
}

actual_stdout="$tmpdir/success-stdout"
actual_stderr="$tmpdir/success-stderr"
args_file="$tmpdir/success-args"
cache_file="$tmpdir/existing-cache-dir/claude-status.json"
mkdir -p "$(dirname "$cache_file")"

run_wrapper "$actual_stdout" "$actual_stderr" "$args_file" "$cache_file" env

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s\n' "$status" >&2
    cat "$actual_stderr" >&2
    exit 1
fi

cmp -s "$input_file" "$actual_stdout"
cmp -s "$input_file" "$cache_file"
assert_no_temp_files "$cache_file"

if [ -s "$actual_stderr" ]; then
    printf 'expected empty stderr, got:\n' >&2
    cat "$actual_stderr" >&2
    exit 1
fi

if [ "$(cat "$args_file")" != "--theme compact" ]; then
    printf 'expected forwarded args "--theme compact", got "%s"\n' "$(cat "$args_file")" >&2
    exit 1
fi

mode="$(file_mode "$cache_file")"
if [ "$mode" != "600" ]; then
    printf 'expected cache file mode 600, got %s\n' "$mode" >&2
    exit 1
fi

# Derive a fixture variant with the given rate-limit fields overridden.
# Usage: make_variant OUTPUT window field value [window field value ...]
make_variant() {
    variant_out="$1"
    shift
    python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
overrides = sys.argv[3:]
for i in range(0, len(overrides), 3):
    window, field, value = overrides[i], overrides[i + 1], overrides[i + 2]
    payload["rate_limits"][window][field] = int(value)
json.dump(payload, open(sys.argv[2], "w"))
' "$input_file" "$variant_out" "$@"
}

# --- a writer with older usage data must not clobber a fresher cache ---

fresher_payload="$tmpdir/fresher-payload.json"
make_variant "$fresher_payload" seven_day used_percentage 25

stale_cache_file="$tmpdir/stale-writer/claude-status.json"
mkdir -p "$(dirname "$stale_cache_file")"
cp "$fresher_payload" "$stale_cache_file"

actual_stdout="$tmpdir/stale-stdout"
actual_stderr="$tmpdir/stale-stderr"
args_file="$tmpdir/stale-args"

run_wrapper "$actual_stdout" "$actual_stderr" "$args_file" "$stale_cache_file" env

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on a stale write\n' "$status" >&2
    cat "$actual_stderr" >&2
    exit 1
fi

cmp -s "$input_file" "$actual_stdout" || {
    printf 'expected statusline passthrough even when the cache write is skipped\n' >&2
    exit 1
}

if ! cmp -s "$fresher_payload" "$stale_cache_file"; then
    printf 'expected stale payload (weekly used 19) to leave fresher cache (weekly used 25) untouched\n' >&2
    exit 1
fi
assert_no_temp_files "$stale_cache_file"

# --- fresher usage in the same cycle replaces the cache ---

older_payload="$tmpdir/older-payload.json"
make_variant "$older_payload" seven_day used_percentage 12

fresher_cache_file="$tmpdir/fresher-writer/claude-status.json"
mkdir -p "$(dirname "$fresher_cache_file")"
cp "$older_payload" "$fresher_cache_file"

run_wrapper "$tmpdir/fresher-stdout" "$tmpdir/fresher-stderr" "$tmpdir/fresher-args" "$fresher_cache_file" env

if [ "$status" -ne 0 ] || ! cmp -s "$input_file" "$fresher_cache_file"; then
    printf 'expected fresher payload (weekly used 19) to replace older cache (weekly used 12)\n' >&2
    exit 1
fi

# --- a new weekly cycle wins even though its usage is lower ---

new_cycle_payload="$tmpdir/new-cycle-payload.json"
make_variant "$new_cycle_payload" seven_day used_percentage 90 seven_day resets_at 1782950400

new_cycle_cache_file="$tmpdir/new-cycle/claude-status.json"
mkdir -p "$(dirname "$new_cycle_cache_file")"
cp "$new_cycle_payload" "$new_cycle_cache_file"

run_wrapper "$tmpdir/cycle-stdout" "$tmpdir/cycle-stderr" "$tmpdir/cycle-args" "$new_cycle_cache_file" env

if [ "$status" -ne 0 ] || ! cmp -s "$input_file" "$new_cycle_cache_file"; then
    printf 'expected payload from a new weekly cycle to replace the previous cycle despite lower usage\n' >&2
    exit 1
fi

# --- an unusable existing cache never blocks the write ---

corrupt_cache_file="$tmpdir/corrupt-cache/claude-status.json"
mkdir -p "$(dirname "$corrupt_cache_file")"
printf 'not json' >"$corrupt_cache_file"

run_wrapper "$tmpdir/corrupt-stdout" "$tmpdir/corrupt-stderr" "$tmpdir/corrupt-args" "$corrupt_cache_file" env

if [ "$status" -ne 0 ] || ! cmp -s "$input_file" "$corrupt_cache_file"; then
    printf 'expected incoming payload to replace an unparseable cache\n' >&2
    exit 1
fi

# --- a wrong-typed field never clobbers usable data (primary guard) ---
# The freshness guard's usability check must match the Swift decoder: a string
# used_percentage the app can't parse must not replace a numeric cache, even
# when python3 is available.

guard_wrong_type_payload="$tmpdir/guard-wrong-type-payload.json"
python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
payload["rate_limits"]["five_hour"]["used_percentage"] = "38"
json.dump(payload, open(sys.argv[2], "w"))
' "$input_file" "$guard_wrong_type_payload"

guard_wrong_type_cache="$tmpdir/guard-wrong-type/claude-status.json"
mkdir -p "$(dirname "$guard_wrong_type_cache")"
cp "$input_file" "$guard_wrong_type_cache"

set +e
PATH="$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$guard_wrong_type_cache" \
    FAKE_STATUSLINE_ARGS_FILE="$tmpdir/guard-wrong-type-args" \
    "$wrapper" --theme compact <"$guard_wrong_type_payload" >"$tmpdir/guard-wrong-type-stdout" 2>"$tmpdir/guard-wrong-type-stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on a wrong-typed payload under the primary guard\n' "$status" >&2
    cat "$tmpdir/guard-wrong-type-stderr" >&2
    exit 1
fi

if ! cmp -s "$guard_wrong_type_payload" "$tmpdir/guard-wrong-type-stdout"; then
    printf 'expected passthrough of the wrong-typed payload under the primary guard\n' >&2
    exit 1
fi

if ! cmp -s "$input_file" "$guard_wrong_type_cache"; then
    printf 'expected numeric cache to survive a string used_percentage under the primary guard\n' >&2
    exit 1
fi

# --- a payload without rate limits never clobbers usable data ---

no_limits_payload="$tmpdir/no-limits-payload.json"
python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
del payload["rate_limits"]
json.dump(payload, open(sys.argv[2], "w"))
' "$input_file" "$no_limits_payload"

no_limits_cache_file="$tmpdir/no-limits/claude-status.json"
mkdir -p "$(dirname "$no_limits_cache_file")"
cp "$input_file" "$no_limits_cache_file"

set +e
PATH="$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$no_limits_cache_file" \
    FAKE_STATUSLINE_ARGS_FILE="$tmpdir/no-limits-args" \
    "$wrapper" --theme compact <"$no_limits_payload" >"$tmpdir/no-limits-stdout" 2>"$tmpdir/no-limits-stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on a payload without rate limits\n' "$status" >&2
    cat "$tmpdir/no-limits-stderr" >&2
    exit 1
fi

if ! cmp -s "$no_limits_payload" "$tmpdir/no-limits-stdout"; then
    printf 'expected passthrough of the rate-limit-free payload to the statusline\n' >&2
    exit 1
fi

if ! cmp -s "$input_file" "$no_limits_cache_file"; then
    printf 'expected cache with rate limits to survive a payload without them\n' >&2
    exit 1
fi

# --- if the freshness guard cannot run, fall open to always-write ---

broken_bin="$tmpdir/broken-bin"
mkdir -p "$broken_bin"
printf '#!/bin/sh\nexit 1\n' >"$broken_bin/python3"
chmod 755 "$broken_bin/python3"

failopen_cache_file="$tmpdir/failopen/claude-status.json"
mkdir -p "$(dirname "$failopen_cache_file")"
cp "$fresher_payload" "$failopen_cache_file"

run_wrapper "$tmpdir/failopen-stdout" "$tmpdir/failopen-stderr" "$tmpdir/failopen-args" "$failopen_cache_file" \
    env PATH="$broken_bin:$fake_bin:$PATH"

if [ "$status" -ne 0 ] || ! cmp -s "$input_file" "$failopen_cache_file"; then
    printf 'expected a broken freshness guard to fall open to the original always-write behavior\n' >&2
    exit 1
fi
assert_no_temp_files "$failopen_cache_file"

# --- even fail-open never replaces usable data with a rate-limit-free payload ---

failopen_no_limits_cache="$tmpdir/failopen-no-limits/claude-status.json"
mkdir -p "$(dirname "$failopen_no_limits_cache")"
cp "$input_file" "$failopen_no_limits_cache"

set +e
PATH="$broken_bin:$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$failopen_no_limits_cache" \
    FAKE_STATUSLINE_ARGS_FILE="$tmpdir/failopen-no-limits-args" \
    "$wrapper" --theme compact <"$no_limits_payload" >"$tmpdir/failopen-no-limits-stdout" 2>"$tmpdir/failopen-no-limits-stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on a rate-limit-free payload with a broken guard\n' "$status" >&2
    cat "$tmpdir/failopen-no-limits-stderr" >&2
    exit 1
fi

if ! cmp -s "$no_limits_payload" "$tmpdir/failopen-no-limits-stdout"; then
    printf 'expected passthrough of the rate-limit-free payload with a broken guard\n' >&2
    exit 1
fi

if ! cmp -s "$input_file" "$failopen_no_limits_cache"; then
    printf 'expected cache with rate limits to survive a rate-limit-free payload even when the guard is broken\n' >&2
    exit 1
fi

# --- fail-open also rejects rate-limit stubs missing the usage windows ---

stub_payload="$tmpdir/stub-payload.json"
python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
payload["rate_limits"] = {}
json.dump(payload, open(sys.argv[2], "w"))
' "$input_file" "$stub_payload"

failopen_stub_cache="$tmpdir/failopen-stub/claude-status.json"
mkdir -p "$(dirname "$failopen_stub_cache")"
cp "$input_file" "$failopen_stub_cache"

set +e
PATH="$broken_bin:$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$failopen_stub_cache" \
    FAKE_STATUSLINE_ARGS_FILE="$tmpdir/failopen-stub-args" \
    "$wrapper" --theme compact <"$stub_payload" >"$tmpdir/failopen-stub-stdout" 2>"$tmpdir/failopen-stub-stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on a rate-limit stub with a broken guard\n' "$status" >&2
    cat "$tmpdir/failopen-stub-stderr" >&2
    exit 1
fi

if ! cmp -s "$input_file" "$failopen_stub_cache"; then
    printf 'expected cache with usage windows to survive an empty rate_limits stub even when the guard is broken\n' >&2
    exit 1
fi

# --- fail-open rejects window stubs that name the windows but carry no usage ---
# The token-level screen must look past the window key names: a payload like
# {"rate_limits":{"five_hour":{},"seven_day":{}}} mentions every window token
# yet has no resets_at/used_percentage for the app to parse.

empty_windows_payload="$tmpdir/empty-windows-payload.json"
python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
payload["rate_limits"] = {"five_hour": {}, "seven_day": {}}
json.dump(payload, open(sys.argv[2], "w"))
' "$input_file" "$empty_windows_payload"

failopen_empty_windows_cache="$tmpdir/failopen-empty-windows/claude-status.json"
mkdir -p "$(dirname "$failopen_empty_windows_cache")"
cp "$input_file" "$failopen_empty_windows_cache"

set +e
PATH="$broken_bin:$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$failopen_empty_windows_cache" \
    FAKE_STATUSLINE_ARGS_FILE="$tmpdir/failopen-empty-windows-args" \
    "$wrapper" --theme compact <"$empty_windows_payload" >"$tmpdir/failopen-empty-windows-stdout" 2>"$tmpdir/failopen-empty-windows-stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on an empty-window rate-limit stub with a broken guard\n' "$status" >&2
    cat "$tmpdir/failopen-empty-windows-stderr" >&2
    exit 1
fi

if ! cmp -s "$empty_windows_payload" "$tmpdir/failopen-empty-windows-stdout"; then
    printf 'expected passthrough of the empty-window stub with a broken guard\n' >&2
    exit 1
fi

if ! cmp -s "$input_file" "$failopen_empty_windows_cache"; then
    printf 'expected cache with usage data to survive an empty-window stub even when the guard is broken\n' >&2
    exit 1
fi

# --- fail-open rejects payloads where only one window carries usage fields ---
# Token names alone can't tell that the fields sit inside both required
# windows: {"five_hour":{...both fields...},"seven_day":{}} mentions every
# token yet the app can't parse seven_day.

partial_windows_payload="$tmpdir/partial-windows-payload.json"
python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
five_hour = payload["rate_limits"]["five_hour"]
payload["rate_limits"] = {"five_hour": five_hour, "seven_day": {}}
json.dump(payload, open(sys.argv[2], "w"))
' "$input_file" "$partial_windows_payload"

failopen_partial_cache="$tmpdir/failopen-partial/claude-status.json"
mkdir -p "$(dirname "$failopen_partial_cache")"
cp "$input_file" "$failopen_partial_cache"

set +e
PATH="$broken_bin:$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$failopen_partial_cache" \
    FAKE_STATUSLINE_ARGS_FILE="$tmpdir/failopen-partial-args" \
    "$wrapper" --theme compact <"$partial_windows_payload" >"$tmpdir/failopen-partial-stdout" 2>"$tmpdir/failopen-partial-stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on a partial-window payload with a broken guard\n' "$status" >&2
    cat "$tmpdir/failopen-partial-stderr" >&2
    exit 1
fi

if ! cmp -s "$partial_windows_payload" "$tmpdir/failopen-partial-stdout"; then
    printf 'expected passthrough of the partial-window payload with a broken guard\n' >&2
    exit 1
fi

if ! cmp -s "$input_file" "$failopen_partial_cache"; then
    printf 'expected cache with both windows to survive a payload missing one window'\''s fields\n' >&2
    exit 1
fi

# --- fail-open rejects windows whose fields are the wrong value type ---
# Key presence isn't enough: the app decodes used_percentage as Int and
# resets_at as a number, so a string like "38" (or an object) is unparseable
# and must not clobber a usable cache.

wrong_type_payload="$tmpdir/wrong-type-payload.json"
python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
payload["rate_limits"]["five_hour"]["used_percentage"] = "38"
json.dump(payload, open(sys.argv[2], "w"))
' "$input_file" "$wrong_type_payload"

failopen_wrong_type_cache="$tmpdir/failopen-wrong-type/claude-status.json"
mkdir -p "$(dirname "$failopen_wrong_type_cache")"
cp "$input_file" "$failopen_wrong_type_cache"

set +e
PATH="$broken_bin:$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$failopen_wrong_type_cache" \
    FAKE_STATUSLINE_ARGS_FILE="$tmpdir/failopen-wrong-type-args" \
    "$wrapper" --theme compact <"$wrong_type_payload" >"$tmpdir/failopen-wrong-type-stdout" 2>"$tmpdir/failopen-wrong-type-stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s on a wrong-type payload with a broken guard\n' "$status" >&2
    cat "$tmpdir/failopen-wrong-type-stderr" >&2
    exit 1
fi

if ! cmp -s "$wrong_type_payload" "$tmpdir/failopen-wrong-type-stdout"; then
    printf 'expected passthrough of the wrong-type payload with a broken guard\n' >&2
    exit 1
fi

if ! cmp -s "$input_file" "$failopen_wrong_type_cache"; then
    printf 'expected cache with numeric fields to survive a payload with a string used_percentage\n' >&2
    exit 1
fi

actual_stdout="$tmpdir/failure-stdout"
actual_stderr="$tmpdir/failure-stderr"
args_file="$tmpdir/failure-args"
cache_file="$tmpdir/failure-cache/claude-status.json"

run_wrapper "$actual_stdout" "$actual_stderr" "$args_file" "$cache_file" env FAKE_STATUSLINE_FAIL=1

if [ "$status" -ne 17 ]; then
    printf 'expected wrapper to propagate status 17, got %s\n' "$status" >&2
    cat "$actual_stderr" >&2
    exit 1
fi

cmp -s "$input_file" "$actual_stdout"
cmp -s "$input_file" "$cache_file"
assert_no_temp_files "$cache_file"

if [ "$(cat "$actual_stderr")" != "synthetic statusline failure" ]; then
    printf 'expected statusline stderr passthrough, got:\n' >&2
    cat "$actual_stderr" >&2
    exit 1
fi

if [ "$(cat "$args_file")" != "--theme compact" ]; then
    printf 'expected forwarded args "--theme compact", got "%s"\n' "$(cat "$args_file")" >&2
    exit 1
fi

mode="$(file_mode "$cache_file")"
if [ "$mode" != "600" ]; then
    printf 'expected cache file mode 600, got %s\n' "$mode" >&2
    exit 1
fi
