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
cat
SH
chmod 755 "$fake_bin/ccstatusline"

input_file="$repo_root/Tests/Fixtures/claude-statusline.json"
actual_stdout="$tmpdir/stdout"
actual_stderr="$tmpdir/stderr"
args_file="$tmpdir/args"
cache_file="$tmpdir/cache/claude-status.json"

set +e
PATH="$fake_bin:$PATH" \
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$cache_file" \
    FAKE_STATUSLINE_ARGS_FILE="$args_file" \
    "$wrapper" --theme compact <"$input_file" >"$actual_stdout" 2>"$actual_stderr"
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'wrapper exited %s\n' "$status" >&2
    cat "$actual_stderr" >&2
    exit 1
fi

cmp -s "$input_file" "$actual_stdout"
cmp -s "$input_file" "$cache_file"

if [ -s "$actual_stderr" ]; then
    printf 'expected empty stderr, got:\n' >&2
    cat "$actual_stderr" >&2
    exit 1
fi

if [ "$(cat "$args_file")" != "--theme compact" ]; then
    printf 'expected forwarded args "--theme compact", got "%s"\n' "$(cat "$args_file")" >&2
    exit 1
fi

if mode="$(stat -f '%Lp' "$cache_file" 2>/dev/null)"; then
    :
else
    mode="$(stat -c '%a' "$cache_file")"
fi

if [ "$mode" != "600" ]; then
    printf 'expected cache file mode 600, got %s\n' "$mode" >&2
    exit 1
fi
