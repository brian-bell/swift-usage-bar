#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle_script="$repo_root/scripts/bundle.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_fails_with() {
    expected="$1"
    shift

    set +e
    output="$(cd "$tmpdir" && "$@" 2>&1)"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        printf 'expected command to fail: %s\n' "$*" >&2
        exit 1
    fi

    if ! grep -Fq "$expected" <<<"$output"; then
        printf 'expected error containing "%s", got:\n%s\n' "$expected" "$output" >&2
        exit 1
    fi
}

assert_fails_with "bundle not found" "$bundle_script" --verify "$tmpdir/Missing.app"

malformed_app="$tmpdir/Malformed.app"
mkdir -p "$malformed_app"
assert_fails_with "missing Contents/Info.plist" "$bundle_script" --verify "$malformed_app"

assert_fails_with "app path must not be empty" "$bundle_script" --output ""
assert_fails_with "app path must not be /" "$bundle_script" --output /
assert_fails_with "app path must end in .app" "$bundle_script" --output "$tmpdir/not-an-app"
