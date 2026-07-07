#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
make_cert="$repo_root/scripts/make-signing-cert"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

cert_text() {
    openssl x509 -in "$1" -noout -text
}

# --- dry run with defaults produces a usable code-signing cert, no keychain writes ---

out_dir="$tmpdir/default"
"$make_cert" --dry-run --out "$out_dir" >"$tmpdir/default-stdout"

[ -f "$out_dir/cert.pem" ] || fail "dry run should write cert.pem"
[ -f "$out_dir/key.pem" ] || fail "dry run should write key.pem"

key_mode="$(stat -f '%Lp' "$out_dir/key.pem")"
[ "$key_mode" = "600" ] || fail "key.pem should be 0600, got $key_mode"

subject="$(openssl x509 -in "$out_dir/cert.pem" -noout -subject)"
case "$subject" in
    *"CN=AIUsageBar Signing"*) ;;
    *) fail "default subject should carry CN=AIUsageBar Signing, got: $subject" ;;
esac
case "$subject" in
    *"OU=AIUSAGEBAR"*) ;;
    *) fail "default subject should carry OU=AIUSAGEBAR (the team identifier), got: $subject" ;;
esac

issuer="$(openssl x509 -in "$out_dir/cert.pem" -noout -issuer | sed 's/^issuer=//')"
subject_only="$(openssl x509 -in "$out_dir/cert.pem" -noout -subject | sed 's/^subject=//')"
[ "$issuer" = "$subject_only" ] || fail "cert should be self-signed (issuer == subject)"

text="$(cert_text "$out_dir/cert.pem")"
printf '%s' "$text" | grep -q "Code Signing" || fail "cert should carry the codeSigning EKU"
printf '%s' "$text" | grep -q "Digital Signature" || fail "cert should carry digitalSignature key usage"
printf '%s' "$text" | grep -q "CA:FALSE" || fail "cert should not be a CA"

cert_pub="$(openssl x509 -in "$out_dir/cert.pem" -noout -pubkey)"
key_pub="$(openssl pkey -in "$out_dir/key.pem" -pubout)"
[ "$cert_pub" = "$key_pub" ] || fail "key.pem should match cert.pem"

# --- custom name, team id, and validity are honored ---

out_dir="$tmpdir/custom"
"$make_cert" --dry-run --out "$out_dir" \
    --name "My Signing Cert" --team-id TESTTEAM01 --days 30 >/dev/null

subject="$(openssl x509 -in "$out_dir/cert.pem" -noout -subject)"
case "$subject" in
    *"CN=My Signing Cert"*) ;;
    *) fail "custom name should land in CN, got: $subject" ;;
esac
case "$subject" in
    *"OU=TESTTEAM01"*) ;;
    *) fail "custom team id should land in OU, got: $subject" ;;
esac

# 30-day cert must already be valid and still valid in 29 days, but expired in 31.
openssl x509 -in "$out_dir/cert.pem" -noout -checkend 0 >/dev/null \
    || fail "custom cert should be valid now"
openssl x509 -in "$out_dir/cert.pem" -noout -checkend $((29 * 86400)) >/dev/null \
    || fail "custom cert should still be valid in 29 days"
if openssl x509 -in "$out_dir/cert.pem" -noout -checkend $((31 * 86400)) >/dev/null; then
    fail "custom 30-day cert should be expired in 31 days"
fi

# --- invalid inputs are rejected before anything is generated ---

expect_rejects() {
    label="$1"
    shift
    out="$tmpdir/reject"
    rm -rf "$out"
    if "$make_cert" --dry-run --out "$out" "$@" >/dev/null 2>"$tmpdir/reject-stderr"; then
        fail "$label should be rejected"
    fi
    [ ! -e "$out/cert.pem" ] || fail "$label should not generate a cert"
    [ -s "$tmpdir/reject-stderr" ] || fail "$label should explain the rejection on stderr"
}

expect_rejects "lowercase team id" --team-id badteam
expect_rejects "team id with symbols" --team-id 'BAD!ID'
expect_rejects "empty team id" --team-id ""
expect_rejects "name containing a slash" --name "bad/name"
expect_rejects "non-numeric days" --days soon
expect_rejects "unknown flag" --bogus

# --- usage is printed on request ---

"$make_cert" --help >"$tmpdir/help-stdout"
grep -q "Usage:" "$tmpdir/help-stdout" || fail "--help should print usage"

printf 'make-signing-cert tests passed\n'
