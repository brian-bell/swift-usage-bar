#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
setup="$repo_root/scripts/setup-statusline"
input_file="$repo_root/Tests/Fixtures/claude-statusline.json"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

json_get() {
    python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value[key]
print(value)
' "$@"
}

# Simulate Claude Code invoking the configured statusline: run the settings
# command string through a shell with the statusline JSON on stdin.
run_configured_statusline() {
    settings_file="$1"
    cache_file="$2"
    stdout_file="$3"

    command_string="$(json_get "$settings_file" statusLine command)"
    set +e
    AI_USAGE_BAR_CLAUDE_STATUS_JSON="$cache_file" \
        sh -c "$command_string" <"$input_file" >"$stdout_file" 2>"$tmpdir/statusline-stderr"
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        printf 'configured statusline command exited %s\n' "$status" >&2
        cat "$tmpdir/statusline-stderr" >&2
        exit 1
    fi
}

# --- existing statusline command is preserved byte-for-byte ---

config_dir="$tmpdir/claude-config"
mkdir -p "$config_dir"

original_bin="$tmpdir/original statusline.sh"
cat >"$original_bin" <<'SH'
#!/usr/bin/env bash
printf 'original render: %s %s / ' "$1" "$2"
cat
SH
chmod 755 "$original_bin"
original_command="'$original_bin' --flag 'two words'"

cat >"$config_dir/settings.json" <<JSON
{
  "model": "opus",
  "statusLine": {
    "type": "command",
    "command": "'$original_bin' --flag 'two words'",
    "padding": 0,
    "refreshInterval": 10
  }
}
JSON

original_settings="$tmpdir/original-settings.json"
cp "$config_dir/settings.json" "$original_settings"

expected_render="$tmpdir/expected-render"
sh -c "$original_command" <"$input_file" >"$expected_render"

if CLAUDE_CONFIG_DIR="$config_dir" "$setup" >"$tmpdir/setup-stdout" 2>"$tmpdir/setup-stderr"; then
    :
else
    printf 'setup-statusline exited %s\n' "$?" >&2
    cat "$tmpdir/setup-stderr" >&2
    exit 1
fi

new_command="$(json_get "$config_dir/settings.json" statusLine command)"
case "$new_command" in
*claude-statusline-cache*) ;;
*)
    printf 'expected statusLine.command to invoke claude-statusline-cache, got "%s"\n' "$new_command" >&2
    exit 1
    ;;
esac

cache_file="$tmpdir/cache/claude-status.json"
run_configured_statusline "$config_dir/settings.json" "$cache_file" "$tmpdir/actual-render"

if ! cmp -s "$expected_render" "$tmpdir/actual-render"; then
    printf 'expected configured statusline to render identically to the original command\n' >&2
    printf 'expected:\n' >&2
    cat "$expected_render" >&2
    printf 'actual:\n' >&2
    cat "$tmpdir/actual-render" >&2
    exit 1
fi

if ! cmp -s "$input_file" "$cache_file"; then
    printf 'expected statusline JSON to be teed to the cache file\n' >&2
    exit 1
fi

if [ "$(json_get "$config_dir/settings.json" model)" != "opus" ]; then
    printf 'expected unrelated settings keys to be preserved\n' >&2
    exit 1
fi

if [ "$(json_get "$config_dir/settings.json" statusLine padding)" != "0" ]; then
    printf 'expected statusLine.padding to be preserved\n' >&2
    exit 1
fi

if [ "$(json_get "$config_dir/settings.json" statusLine refreshInterval)" != "10" ]; then
    printf 'expected statusLine.refreshInterval to be preserved\n' >&2
    exit 1
fi

# The shim republishes the command string from settings.json (mode 600),
# so it must stay owner-only, as must its directory.
file_mode() {
    if stat -f '%Lp' "$1" 2>/dev/null; then
        return
    fi
    stat -c '%a' "$1"
}

shim_file="$config_dir/ai-usage-bar/statusline-passthrough.sh"
if [ "$(file_mode "$shim_file")" != "700" ]; then
    printf 'expected shim mode 700, got %s\n' "$(file_mode "$shim_file")" >&2
    exit 1
fi

if [ "$(file_mode "$(dirname "$shim_file")")" != "700" ]; then
    printf 'expected shim directory mode 700, got %s\n' "$(file_mode "$(dirname "$shim_file")")" >&2
    exit 1
fi

printf 'ok: existing statusline preserved\n'

# --- rerunning is idempotent: the wrapper never wraps itself ---

settings_before_rerun="$(cat "$config_dir/settings.json")"
shim_before_rerun="$(cat "$config_dir/ai-usage-bar/statusline-passthrough.sh")"

if ! CLAUDE_CONFIG_DIR="$config_dir" "$setup" >"$tmpdir/rerun-stdout" 2>"$tmpdir/rerun-stderr"; then
    printf 'expected rerun to exit 0\n' >&2
    cat "$tmpdir/rerun-stderr" >&2
    exit 1
fi

if [ "$(cat "$config_dir/settings.json")" != "$settings_before_rerun" ]; then
    printf 'expected rerun to leave settings.json unchanged\n' >&2
    exit 1
fi

if [ "$(cat "$config_dir/ai-usage-bar/statusline-passthrough.sh")" != "$shim_before_rerun" ]; then
    printf 'expected rerun to leave the passthrough shim unchanged\n' >&2
    exit 1
fi

printf 'ok: rerun is idempotent\n'

# --- no prior settings: cache is written, statusline renders nothing ---

fresh_config_dir="$tmpdir/fresh-claude-config"

if ! CLAUDE_CONFIG_DIR="$fresh_config_dir" "$setup" >"$tmpdir/fresh-stdout" 2>"$tmpdir/fresh-stderr"; then
    printf 'expected setup with no settings.json to exit 0\n' >&2
    cat "$tmpdir/fresh-stderr" >&2
    exit 1
fi

fresh_cache_file="$tmpdir/fresh-cache/claude-status.json"
run_configured_statusline "$fresh_config_dir/settings.json" "$fresh_cache_file" "$tmpdir/fresh-render"

if [ -s "$tmpdir/fresh-render" ]; then
    printf 'expected an empty render when no statusline was configured before, got:\n' >&2
    cat "$tmpdir/fresh-render" >&2
    exit 1
fi

if ! cmp -s "$input_file" "$fresh_cache_file"; then
    printf 'expected statusline JSON to be teed to the cache file on a fresh config\n' >&2
    exit 1
fi

printf 'ok: fresh config renders nothing and still fills the cache\n'

# --- the pre-existing settings.json is backed up before being rewritten ---

backup_file="$config_dir/settings.json.ai-usage-bar-backup"
if ! cmp -s "$original_settings" "$backup_file"; then
    printf 'expected %s to hold the original settings.json\n' "$backup_file" >&2
    exit 1
fi

printf 'ok: original settings backed up\n'

# --- a corrupt settings.json is left untouched ---

corrupt_config_dir="$tmpdir/corrupt-claude-config"
mkdir -p "$corrupt_config_dir"
printf '{ not json' >"$corrupt_config_dir/settings.json"

set +e
CLAUDE_CONFIG_DIR="$corrupt_config_dir" "$setup" >"$tmpdir/corrupt-stdout" 2>"$tmpdir/corrupt-stderr"
corrupt_status=$?
set -e

if [ "$corrupt_status" -eq 0 ]; then
    printf 'expected setup to fail on unparseable settings.json\n' >&2
    exit 1
fi

if [ "$(cat "$corrupt_config_dir/settings.json")" != '{ not json' ]; then
    printf 'expected corrupt settings.json to be left untouched\n' >&2
    exit 1
fi

printf 'ok: corrupt settings left untouched\n'
