#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_app_path="$repo_root/AIUsageBar.app"
product_name="AIUsageBarApp"
bundle_identifier="dev.brianbell.AIUsageBar"
staging_parent=""

cleanup_staging() {
    if [ -n "$staging_parent" ]; then
        rm -rf "$staging_parent"
    fi
}
trap cleanup_staging EXIT

usage() {
    cat <<'USAGE'
Usage:
  scripts/bundle.sh [--output APP_PATH]
  scripts/bundle.sh --verify [APP_PATH]

Builds and signs AIUsageBar.app, or verifies an existing bundle.

Environment:
  CODESIGN_IDENTITY  Signing identity passed to `codesign --sign`. Defaults to
                     "-" (ad-hoc). Set it to a self-signed code-signing
                     certificate's name to get a stable signature across
                     rebuilds, so Keychain "Always Allow" grants survive.
USAGE
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

validate_app_path() {
    local app_path="$1"

    if [ -z "$app_path" ]; then
        fail "app path must not be empty"
    fi

    if [ "$app_path" = "/" ]; then
        fail "app path must not be /"
    fi

    case "$app_path" in
        *.app) ;;
        *) fail "app path must end in .app: $app_path" ;;
    esac
}

validate_build_output_path() {
    local app_path="$1"
    validate_app_path "$app_path"

    if [ "$(basename "$app_path")" != "AIUsageBar.app" ]; then
        fail "build output basename must be AIUsageBar.app: $app_path"
    fi

    case "$app_path" in
        ../*|*/../*|*/..|..)
            fail "build output path must not contain ..: $app_path"
            ;;
    esac
}

plist_value() {
    local plist="$1"
    local key="$2"

    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

expect_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual

    actual="$(plist_value "$plist" "$key" || true)"
    if [ "$actual" != "$expected" ]; then
        fail "Info.plist $key expected $expected, got ${actual:-<missing>}"
    fi
}

verify_bundle() {
    local app_path="$1"
    local plist
    local executable
    validate_app_path "$app_path"

    if [ ! -d "$app_path" ]; then
        fail "bundle not found: $app_path"
    fi

    plist="$app_path/Contents/Info.plist"
    if [ ! -f "$plist" ]; then
        fail "missing Contents/Info.plist: $plist"
    fi

    if ! plutil -lint "$plist" >/dev/null; then
        fail "invalid Info.plist: $plist"
    fi

    expect_plist_value "$plist" CFBundleIdentifier "$bundle_identifier"
    expect_plist_value "$plist" CFBundleExecutable "$product_name"
    expect_plist_value "$plist" CFBundlePackageType APPL
    expect_plist_value "$plist" LSUIElement true

    executable="$app_path/Contents/MacOS/$product_name"
    if [ ! -f "$executable" ]; then
        fail "missing executable: $executable"
    fi

    if [ ! -x "$executable" ]; then
        fail "executable is not executable: $executable"
    fi

    if ! codesign -v "$app_path" >/dev/null 2>&1; then
        fail "codesign verification failed: $app_path"
    fi
}

replace_with_staged_bundle() {
    local staged_app="$1"
    local app_path="$2"
    local staging_parent="$3"
    local backup_app=""

    if [ -e "$app_path" ]; then
        backup_app="$staging_parent/PreviousAIUsageBar.app"
        mv "$app_path" "$backup_app"
    fi

    if ! mv "$staged_app" "$app_path"; then
        if [ -n "$backup_app" ] && [ -e "$backup_app" ]; then
            rm -rf "$app_path"
            mv "$backup_app" "$app_path" || true
        fi
        fail "failed to install app bundle: $app_path"
    fi

    if [ -n "$backup_app" ]; then
        rm -rf "$backup_app"
    fi
}

build_bundle() {
    local app_path="$1"
    local bin_path
    local built_executable
    local output_parent
    local staged_app
    local plist
    validate_build_output_path "$app_path"

    swift build --package-path "$repo_root" -c release --product "$product_name"
    bin_path="$(swift build --package-path "$repo_root" -c release --show-bin-path)"
    built_executable="$bin_path/$product_name"
    if [ ! -x "$built_executable" ]; then
        fail "release executable not found: $built_executable"
    fi

    output_parent="$(dirname "$app_path")"
    mkdir -p "$output_parent"
    staging_parent="$(mktemp -d "$output_parent/.AIUsageBar.bundle.XXXXXX")"
    staged_app="$staging_parent/AIUsageBar.app"

    mkdir -p "$staged_app/Contents/MacOS"

    plist="$staged_app/Contents/Info.plist"
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>AIUsageBar</string>
    <key>CFBundleExecutable</key>
    <string>$product_name</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_identifier</string>
    <key>CFBundleName</key>
    <string>AIUsageBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

    install -m 755 "$built_executable" "$staged_app/Contents/MacOS/$product_name"
    local codesign_identity="${CODESIGN_IDENTITY:--}"
    if ! codesign --force --sign "$codesign_identity" "$staged_app"; then
        fail "codesign signing failed for identity: $codesign_identity"
    fi
    verify_bundle "$staged_app"

    replace_with_staged_bundle "$staged_app" "$app_path" "$staging_parent"
    rm -rf "$staging_parent"
    verify_bundle "$app_path"
}

mode="build"
app_path="$default_app_path"
verify_requested="false"
output_requested="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --verify)
            if [ "$output_requested" = "true" ]; then
                fail "--verify cannot be combined with --output"
            fi
            verify_requested="true"
            mode="verify"
            shift
            if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
                app_path="$1"
                shift
            fi
            ;;
        --output)
            if [ "$verify_requested" = "true" ]; then
                fail "--output cannot be used with --verify"
            fi
            output_requested="true"
            shift
            if [ "$#" -eq 0 ]; then
                fail "--output requires APP_PATH"
            fi
            app_path="$1"
            shift
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
done

case "$mode" in
    verify)
        verify_bundle "$app_path"
        ;;
    build)
        build_bundle "$app_path"
        ;;
esac
