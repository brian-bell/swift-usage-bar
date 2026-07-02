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
