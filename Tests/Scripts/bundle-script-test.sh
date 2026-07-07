#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle_script="$repo_root/scripts/bundle.sh"
product_name="AIUsageBarApp"
bundle_identifier="dev.brianbell.AIUsageBar"

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

    if ! grep -Fq -- "$expected" <<<"$output"; then
        printf 'expected error containing "%s", got:\n%s\n' "$expected" "$output" >&2
        exit 1
    fi
}

write_info_plist() {
    app_path="$1"
    executable="${2:-$product_name}"
    package_type="${3:-APPL}"
    lsui_element="${4:-true}"
    identifier="${5:-$bundle_identifier}"

    mkdir -p "$app_path/Contents"
    if [ "$lsui_element" = "true" ]; then
        lsui_value="<true/>"
    else
        lsui_value="<false/>"
    fi

    cat >"$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
PLIST

    if [ "$identifier" != "__omit__" ]; then
        cat >>"$app_path/Contents/Info.plist" <<PLIST
    <key>CFBundleIdentifier</key>
    <string>$identifier</string>
PLIST
    fi

    cat >>"$app_path/Contents/Info.plist" <<PLIST
    <key>CFBundleExecutable</key>
    <string>$executable</string>
    <key>CFBundlePackageType</key>
    <string>$package_type</string>
    <key>LSUIElement</key>
    $lsui_value
</dict>
</plist>
PLIST
}

write_executable() {
    app_path="$1"
    executable_name="${2:-$product_name}"
    mode="${3:-755}"

    mkdir -p "$app_path/Contents/MacOS"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$app_path/Contents/MacOS/$executable_name"
    chmod "$mode" "$app_path/Contents/MacOS/$executable_name"
}

assert_fails_with "bundle not found" "$bundle_script" --verify "$tmpdir/Missing.app"

malformed_app="$tmpdir/Malformed.app"
mkdir -p "$malformed_app"
assert_fails_with "missing Contents/Info.plist" "$bundle_script" --verify "$malformed_app"

invalid_plist_app="$tmpdir/InvalidPlist.app"
mkdir -p "$invalid_plist_app/Contents"
printf 'not a plist\n' >"$invalid_plist_app/Contents/Info.plist"
assert_fails_with "invalid Info.plist" "$bundle_script" --verify "$invalid_plist_app"

wrong_executable_app="$tmpdir/WrongExecutable.app"
write_info_plist "$wrong_executable_app" "OtherExecutable"
assert_fails_with "CFBundleExecutable expected $product_name" "$bundle_script" --verify "$wrong_executable_app"

missing_identifier_app="$tmpdir/MissingIdentifier.app"
write_info_plist "$missing_identifier_app" "$product_name" "APPL" "true" "__omit__"
write_executable "$missing_identifier_app"
assert_fails_with "CFBundleIdentifier expected $bundle_identifier" "$bundle_script" --verify "$missing_identifier_app"

wrong_identifier_app="$tmpdir/WrongIdentifier.app"
write_info_plist "$wrong_identifier_app" "$product_name" "APPL" "true" "com.example.Other"
write_executable "$wrong_identifier_app"
assert_fails_with "CFBundleIdentifier expected $bundle_identifier" "$bundle_script" --verify "$wrong_identifier_app"

wrong_package_app="$tmpdir/WrongPackage.app"
write_info_plist "$wrong_package_app" "$product_name" "BNDL"
assert_fails_with "CFBundlePackageType expected APPL" "$bundle_script" --verify "$wrong_package_app"

dock_app="$tmpdir/DockApp.app"
write_info_plist "$dock_app" "$product_name" "APPL" "false"
assert_fails_with "LSUIElement expected true" "$bundle_script" --verify "$dock_app"

missing_executable_app="$tmpdir/MissingExecutable.app"
write_info_plist "$missing_executable_app"
assert_fails_with "missing executable" "$bundle_script" --verify "$missing_executable_app"

nonexecutable_app="$tmpdir/NonExecutable.app"
write_info_plist "$nonexecutable_app"
write_executable "$nonexecutable_app" "$product_name" "644"
assert_fails_with "executable is not executable" "$bundle_script" --verify "$nonexecutable_app"

unsigned_app="$tmpdir/Unsigned.app"
write_info_plist "$unsigned_app"
write_executable "$unsigned_app"
assert_fails_with "codesign verification failed" "$bundle_script" --verify "$unsigned_app"

assert_fails_with "app path must not be empty" "$bundle_script" --output ""
assert_fails_with "app path must not be /" "$bundle_script" --output /
assert_fails_with "app path must end in .app" "$bundle_script" --output "$tmpdir/not-an-app"
assert_fails_with "build output basename must be AIUsageBar.app" "$bundle_script" --output "$tmpdir/Other.app"
assert_fails_with "build output path must not contain .." "$bundle_script" --output "../AIUsageBar.app"
assert_fails_with "--output cannot be used with --verify" "$bundle_script" --verify --output "$tmpdir/AIUsageBar.app"

built_app="$tmpdir/AIUsageBar.app"
mkdir -p "$built_app/Contents/MacOS"
touch "$built_app/Contents/MacOS/stale-file"

(cd "$tmpdir" && "$bundle_script" --output "$built_app")

if [ -e "$built_app/Contents/MacOS/stale-file" ]; then
    printf 'expected build to remove stale bundle contents\n' >&2
    exit 1
fi

"$bundle_script" --verify "$built_app"
codesign -v "$built_app"

if ! find "$built_app/Contents/Resources/AIUsageBar_AIUsageBarApp.bundle" -name ProviderIcon-claude.svg -print -quit | grep -q .; then
    printf 'expected built bundle to include Claude provider icon resource\n' >&2
    exit 1
fi

if ! find "$built_app/Contents/Resources/AIUsageBar_AIUsageBarApp.bundle" -name ProviderIcon-codex.svg -print -quit | grep -q .; then
    printf 'expected built bundle to include Codex provider icon resource\n' >&2
    exit 1
fi

# CODESIGN_IDENTITY selects the signing identity; a bogus identity fails at the
# signing step with a deterministic message (the swift build is cached from above).
bogus_identity="AIUsageBar No Such Signing Identity"
assert_fails_with "codesign signing failed for identity: $bogus_identity" \
    env CODESIGN_IDENTITY="$bogus_identity" "$bundle_script" --output "$built_app"

# A failed signing run must not leave a staging directory next to the output.
if compgen -G "$tmpdir/.AIUsageBar.bundle.*" >/dev/null; then
    printf 'expected failed build to clean up its staging directory\n' >&2
    exit 1
fi

# The default (unset CODESIGN_IDENTITY) signs ad-hoc and still verifies.
(cd "$tmpdir" && "$bundle_script" --output "$built_app")
"$bundle_script" --verify "$built_app"

# With CODESIGN_IDENTITY unset, bundle.sh prefers an installed Apple
# Development identity — its signature carries a genuine TeamIdentifier, so
# keychain partition-list grants record a stable teamid: entry and rebuilds
# stop prompting — and falls back to ad-hoc when none exists. Stub codesign
# to capture argv and security to control the identity list; the swift build
# is cached from the runs above.
stub_bin="$tmpdir/stub-bin"
mkdir -p "$stub_bin"
apple_identity="Apple Development: Test User (TEAM123ABC)"

cat >"$stub_bin/security" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "find-identity" ]; then
    if [ -f "$tmpdir/no-identities" ]; then
        printf '     0 valid identities found\n'
    else
        printf '  1) 0123456789ABCDEF "$apple_identity"\n'
        printf '     1 valid identities found\n'
    fi
    exit 0
fi
exec /usr/bin/security "\$@"
STUB
cat >"$stub_bin/codesign" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmpdir/codesign-args.log"
exit 0
STUB
chmod 755 "$stub_bin/security" "$stub_bin/codesign"

rm -f "$tmpdir/codesign-args.log" "$tmpdir/no-identities"
(cd "$tmpdir" && PATH="$stub_bin:$PATH" "$bundle_script" --output "$built_app")
if ! grep -q -- "--force --sign $apple_identity " "$tmpdir/codesign-args.log"; then
    printf 'expected default signing to pick the Apple Development identity, got:\n%s\n' \
        "$(cat "$tmpdir/codesign-args.log")" >&2
    exit 1
fi

# No valid identities installed: ad-hoc, exactly as before.
rm -f "$tmpdir/codesign-args.log"
touch "$tmpdir/no-identities"
(cd "$tmpdir" && PATH="$stub_bin:$PATH" "$bundle_script" --output "$built_app")
if ! grep -q -- "--force --sign - " "$tmpdir/codesign-args.log"; then
    printf 'expected ad-hoc fallback with no identities, got:\n%s\n' \
        "$(cat "$tmpdir/codesign-args.log")" >&2
    exit 1
fi

# An explicit CODESIGN_IDENTITY always wins over auto-detection.
rm -f "$tmpdir/codesign-args.log" "$tmpdir/no-identities"
(cd "$tmpdir" && PATH="$stub_bin:$PATH" CODESIGN_IDENTITY="AIUsageBar Signing" \
    "$bundle_script" --output "$built_app")
if ! grep -q -- "--force --sign AIUsageBar Signing " "$tmpdir/codesign-args.log"; then
    printf 'expected explicit CODESIGN_IDENTITY to override auto-detection, got:\n%s\n' \
        "$(cat "$tmpdir/codesign-args.log")" >&2
    exit 1
fi
