#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_app_path="$repo_root/AIUsageBar.app"
product_name="AIUsageBarApp"

usage() {
    cat <<'USAGE'
Usage:
  scripts/bundle.sh [--output APP_PATH]
  scripts/bundle.sh --verify [APP_PATH]

Builds and ad-hoc signs AIUsageBar.app, or verifies an existing bundle.
USAGE
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

validate_app_path() {
    app_path="$1"

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

plist_value() {
    plist="$1"
    key="$2"

    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

expect_plist_value() {
    plist="$1"
    key="$2"
    expected="$3"

    actual="$(plist_value "$plist" "$key" || true)"
    if [ "$actual" != "$expected" ]; then
        fail "Info.plist $key expected $expected, got ${actual:-<missing>}"
    fi
}

verify_bundle() {
    app_path="$1"
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

build_bundle() {
    app_path="$1"
    validate_app_path "$app_path"
    fail "bundle build is not implemented yet"
}

mode="build"
app_path="$default_app_path"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --verify)
            mode="verify"
            shift
            if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
                app_path="$1"
                shift
            fi
            ;;
        --output)
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
