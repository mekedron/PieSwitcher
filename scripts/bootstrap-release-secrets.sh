#!/usr/bin/env bash
# bootstrap-release-secrets.sh
#
# Walks you through generating + uploading every GitHub Actions secret the
# PieSwitcher release workflow (.github/workflows/release.yml) needs.
#
# Run once from the repo root after you have followed docs/release-setup.md
# and collected the Apple Developer artifacts (certificate .p12, App Store
# Connect .p8 + IDs, and optional Homebrew PAT). Re-running is safe — it
# replaces existing secrets in place without leaving orphans, and re-uses
# the Sparkle key already in the project root.
#
# Usage:
#   ./scripts/bootstrap-release-secrets.sh             # interactive
#   ./scripts/bootstrap-release-secrets.sh --skip-homebrew  # never prompt for Homebrew PAT
#   ./scripts/bootstrap-release-secrets.sh --help

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_HOMEBREW_FLAG=0
for arg in "$@"; do
    case "$arg" in
        --skip-homebrew) SKIP_HOMEBREW_FLAG=1 ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Run with --help for usage." >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Pretty output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$(tput bold || true)
    DIM=$(tput dim || true)
    RED=$(tput setaf 1 || true)
    GREEN=$(tput setaf 2 || true)
    YELLOW=$(tput setaf 3 || true)
    BLUE=$(tput setaf 4 || true)
    RESET=$(tput sgr0 || true)
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

say()    { printf '%s\n' "${BLUE}==>${RESET} $*"; }
ok()     { printf '%s\n' "${GREEN}✓${RESET} $*"; }
warn()   { printf '%s\n' "${YELLOW}⚠${RESET}  $*" >&2; }
fail()   { printf '%s\n' "${RED}✗${RESET} $*" >&2; exit 1; }
header() { printf '\n%s\n' "${BOLD}$*${RESET}"; }

# ---------------------------------------------------------------------------
# Temp scratch dir — every plaintext secret goes here and is wiped on exit
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d -t pieswitcher-bootstrap.XXXXXX)
chmod 700 "$TMPDIR"

cleanup() {
    local code=$?
    if [ -d "$TMPDIR" ]; then
        find "$TMPDIR" -type f -exec rm -f {} +
        rmdir "$TMPDIR" 2>/dev/null || rm -rf "$TMPDIR"
    fi
    if [ "$code" -ne 0 ]; then
        warn "Aborted (exit ${code}). No state left in ${TMPDIR}."
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
header "Pre-flight checks"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
    fail "Not inside a git working tree. cd into the PieSwitcher repo and re-run."
fi
cd "$REPO_ROOT"
ok "Repo root: ${REPO_ROOT}"

if ! command -v gh >/dev/null 2>&1; then
    fail "GitHub CLI (\`gh\`) not found. Install: brew install gh"
fi
ok "gh CLI present ($(gh --version | head -1))"

if ! gh auth status >/dev/null 2>&1; then
    fail "gh is not authenticated. Run \`gh auth login\` first."
fi
ok "gh authenticated"

# Determine the GitHub repo from origin
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
if [ -z "$REMOTE_URL" ]; then
    fail "No 'origin' git remote set. Add it before running this script."
fi
# Strip protocol/host, .git suffix → owner/name
REPO_SLUG=$(echo "$REMOTE_URL" \
    | sed -E 's#(git@github.com:|https://github.com/)##' \
    | sed -E 's#\.git$##')
if [ -z "$REPO_SLUG" ] || [ "$REPO_SLUG" = "$REMOTE_URL" ]; then
    fail "Could not parse a GitHub owner/repo from origin URL: ${REMOTE_URL}"
fi
ok "Target repo: ${REPO_SLUG}"

# Sanity check: confirm we can list secrets on this repo
if ! gh secret list --repo "$REPO_SLUG" >/dev/null 2>&1; then
    fail "gh cannot list secrets on ${REPO_SLUG}. Check that your gh login has access."
fi
ok "gh has access to repo secrets"

# ---------------------------------------------------------------------------
# Summary tracking
# ---------------------------------------------------------------------------
# One line per secret: "<name>\t<status>" where status is one of:
#   SET-GENERATED, SET-FROM-FILE, SET-FROM-INPUT, REUSED, SKIPPED
SUMMARY=""
record() {
    SUMMARY="${SUMMARY}${1}|${2}"$'\n'
}

# Push a secret to GitHub via gh.  Reads value from stdin so it never appears
# in the process list and is never written to disk.
push_secret() {
    local name=$1
    local status=$2
    local value
    value=$(cat)
    if [ -z "$value" ]; then
        warn "Refusing to push empty value for ${name}"
        record "$name" "SKIPPED"
        return
    fi
    printf '%s' "$value" | gh secret set "$name" --repo "$REPO_SLUG"
    ok "Set ${BOLD}${name}${RESET}"
    record "$name" "$status"
}

# ---------------------------------------------------------------------------
# Existing secrets — used to decide "reuse vs regenerate"
# ---------------------------------------------------------------------------
EXISTING_SECRETS=$(gh secret list --repo "$REPO_SLUG" --json name --jq '.[].name' 2>/dev/null || true)
has_secret() { echo "$EXISTING_SECRETS" | grep -qx "$1"; }

# ---------------------------------------------------------------------------
# Step 1: keychain password (auto-generated, random)
# ---------------------------------------------------------------------------
header "Step 1 — Keychain Password (auto-generated)"
say "A random throw-away password used by the CI runner to unlock the"
say "temporary keychain it imports your .p12 into. You never need this value."
KEYCHAIN_PWD=$(openssl rand -base64 24 | tr -d '\n')
printf '%s' "$KEYCHAIN_PWD" | push_secret "MACOS_KEYCHAIN_PASSWORD" "SET-GENERATED"

# ---------------------------------------------------------------------------
# Step 2: Sparkle Ed25519 keypair
# ---------------------------------------------------------------------------
header "Step 2 — Sparkle EdDSA Keypair"
SPARKLE_KEY_FILE="${REPO_ROOT}/sparkle_private_key"
SPARKLE_PUB_PLIST="${REPO_ROOT}/PieSwitcher/Info.plist"

REGENERATED_SPARKLE=0
if [ -f "$SPARKLE_KEY_FILE" ] && [ -s "$SPARKLE_KEY_FILE" ]; then
    ok "Found existing Sparkle private key at ${DIM}${SPARKLE_KEY_FILE}${RESET}"
    say "Re-using it. (Delete the file and re-run this script to regenerate.)"
else
    say "No Sparkle private key found — generating one now."
    # Sparkle's generate_keys writes the private key to the macOS keychain,
    # NOT to a file. We do it ourselves with openssl so the key lives in the
    # gitignored sparkle_private_key file, which matches the existing pattern
    # in this repo and lets us hand the same string to sign_update later.
    # Sparkle 2.7+ sign_update expects the "new format" private key file:
    # base64 of the 32-byte Ed25519 seed only (NOT seed+pubkey concatenated).
    # The older 96-byte format also still works, but 64-byte seed+pub does
    # NOT — sign_update 2.9.2 rejects it with a misleading "must be 64 or 96
    # bytes" error message even though it really wants 32 or 96 (verified
    # empirically against the 2.9.2 sign_update binary). The 32-byte seed is
    # canonical: `generate_keys -x` produces the same.
    PEM="${TMPDIR}/ed25519.pem"
    openssl genpkey -algorithm ED25519 -out "$PEM"
    SPARKLE_PUB=$(python3 - "$PEM" "$SPARKLE_KEY_FILE" <<'PYEOF'
import base64, subprocess, sys
pem_path, out_path = sys.argv[1], sys.argv[2]

# Extract raw private key (32 bytes) and derive the public key bytes.
# `openssl pkey -outform DER` includes the raw key wrapped in PKCS#8.
priv_der = subprocess.check_output(["openssl", "pkey", "-in", pem_path, "-outform", "DER"])
# PKCS#8 ED25519 private key: the last 32 bytes are the raw seed.
priv_raw = priv_der[-32:]

pub_der = subprocess.check_output(["openssl", "pkey", "-in", pem_path, "-pubout", "-outform", "DER"])
# The DER encoding of an Ed25519 public key ends with the 32-byte key.
pub_raw = pub_der[-32:]

# Sparkle's "new format" private key is base64 of the 32-byte seed only.
# The public key is derived deterministically from the seed and lives in
# the app's Info.plist as SUPublicEDKey.
priv_b64 = base64.b64encode(priv_raw).decode()
pub_b64 = base64.b64encode(pub_raw).decode()

with open(out_path, "w") as f:
    f.write(priv_b64)

# Surface ONLY the public key on stdout — caller captures it.
print(pub_b64)
PYEOF
)
    REGENERATED_SPARKLE=1
    chmod 600 "$SPARKLE_KEY_FILE"
    ok "Wrote new Sparkle private key to ${DIM}${SPARKLE_KEY_FILE}${RESET} (gitignored)"
    say "Public key (paste into ${SPARKLE_PUB_PLIST} as ${BOLD}SUPublicEDKey${RESET} if not already correct):"
    echo "    ${SPARKLE_PUB}"
    if [ -f "$SPARKLE_PUB_PLIST" ]; then
        EXISTING_PUB=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$SPARKLE_PUB_PLIST" 2>/dev/null || true)
        if [ -n "$EXISTING_PUB" ] && [ "$EXISTING_PUB" != "$SPARKLE_PUB" ]; then
            warn "Info.plist SUPublicEDKey ('${EXISTING_PUB}') does not match the newly-generated public key."
            warn "Sparkle clients running the OLD public key will REJECT updates signed with this NEW private key."
            warn "Update Info.plist before shipping, or restore the matching private key."
        fi
    fi
fi

if [ "$REGENERATED_SPARKLE" -eq 0 ] && has_secret "SPARKLE_PRIVATE_KEY"; then
    # Local key file still present and a remote secret already exists; we
    # still re-push to guarantee they're in sync (the user may have rotated
    # the file out-of-band).
    push_secret "SPARKLE_PRIVATE_KEY" "REUSED" < "$SPARKLE_KEY_FILE"
elif [ "$REGENERATED_SPARKLE" -eq 1 ]; then
    push_secret "SPARKLE_PRIVATE_KEY" "SET-GENERATED" < "$SPARKLE_KEY_FILE"
else
    push_secret "SPARKLE_PRIVATE_KEY" "SET-FROM-FILE" < "$SPARKLE_KEY_FILE"
fi

# ---------------------------------------------------------------------------
# Step 3: Developer ID Application .p12
# ---------------------------------------------------------------------------
header "Step 3 — Developer ID Application Certificate (.p12)"
say "This is the .p12 file you exported from Keychain Access in"
say "docs/release-setup.md (the cert+key bundle for ${BOLD}Developer ID Application${RESET})."

while true; do
    printf '%sPath to Developer ID Application .p12 file:%s ' "$BOLD" "$RESET"
    read -r P12_PATH
    # Trim quotes / drag-and-drop escapes that Terminal sometimes adds
    P12_PATH=$(printf '%s' "$P12_PATH" | sed -e 's/^"//' -e 's/"$//' -e "s/\\\\\\([[:space:]]\\)/\\1/g")
    if [ -z "$P12_PATH" ]; then
        warn "Empty path. Try again."
        continue
    fi
    if [ ! -f "$P12_PATH" ]; then
        warn "Not a file: ${P12_PATH}"
        continue
    fi
    break
done

# Masked passphrase prompt (stty -echo). We never log this value.
printf '%s.p12 export passphrase (input hidden):%s ' "$BOLD" "$RESET"
stty -echo 2>/dev/null || true
read -r P12_PASS
stty echo 2>/dev/null || true
printf '\n'
if [ -z "$P12_PASS" ]; then
    warn "Empty passphrase — that's allowed only if you exported the .p12 without one. Continuing."
fi

# Sanity-check: openssl can actually open it with that passphrase
if ! openssl pkcs12 -in "$P12_PATH" -nokeys -passin "pass:${P12_PASS}" -legacy -info >/dev/null 2>&1 \
   && ! openssl pkcs12 -in "$P12_PATH" -nokeys -passin "pass:${P12_PASS}" -info >/dev/null 2>&1; then
    fail ".p12 + passphrase combination is not valid — openssl could not read it."
fi
ok ".p12 + passphrase combination accepted by openssl"

base64 -i "$P12_PATH" | tr -d '\n' | push_secret "MACOS_CERTIFICATE_P12_BASE64" "SET-FROM-FILE"
printf '%s' "$P12_PASS" | push_secret "MACOS_CERTIFICATE_P12_PASSWORD" "SET-FROM-INPUT"

# ---------------------------------------------------------------------------
# Step 4: App Store Connect API key for notarization
# ---------------------------------------------------------------------------
header "Step 4 — App Store Connect API Key (notarization)"
say "From the App Store Connect → Users and Access → Integrations → Team Keys"
say "page (per docs/release-setup.md): the ${BOLD}Issuer ID${RESET}, the ${BOLD}Key ID${RESET},"
say "and the downloaded ${BOLD}.p8 file${RESET}."

printf '%sIssuer ID:%s ' "$BOLD" "$RESET"
read -r ISSUER_ID
[ -z "$ISSUER_ID" ] && fail "Issuer ID cannot be empty."

printf '%sKey ID:%s ' "$BOLD" "$RESET"
read -r KEY_ID
[ -z "$KEY_ID" ] && fail "Key ID cannot be empty."

while true; do
    printf '%sPath to .p8 file:%s ' "$BOLD" "$RESET"
    read -r P8_PATH
    P8_PATH=$(printf '%s' "$P8_PATH" | sed -e 's/^"//' -e 's/"$//' -e "s/\\\\\\([[:space:]]\\)/\\1/g")
    if [ -z "$P8_PATH" ]; then
        warn "Empty path. Try again."
        continue
    fi
    if [ ! -f "$P8_PATH" ]; then
        warn "Not a file: ${P8_PATH}"
        continue
    fi
    if ! head -1 "$P8_PATH" | grep -q "PRIVATE KEY"; then
        warn "File does not look like a PEM .p8 (missing 'PRIVATE KEY' header). Re-confirm or try again."
        printf 'Continue anyway? [y/N] '
        read -r ANS
        case "$ANS" in
            y|Y) break ;;
            *) continue ;;
        esac
    fi
    break
done

printf '%s' "$ISSUER_ID" | push_secret "MACOS_NOTARY_ISSUER_ID" "SET-FROM-INPUT"
printf '%s' "$KEY_ID"    | push_secret "MACOS_NOTARY_KEY_ID"    "SET-FROM-INPUT"
base64 -i "$P8_PATH" | tr -d '\n' | push_secret "MACOS_NOTARY_KEY_P8_BASE64" "SET-FROM-FILE"

# ---------------------------------------------------------------------------
# Step 5: Homebrew tap PAT (optional)
# ---------------------------------------------------------------------------
header "Step 5 — Homebrew Tap PAT (optional)"
HOMEBREW_DECISION="skip"
if [ "$SKIP_HOMEBREW_FLAG" -eq 1 ]; then
    say "${DIM}--skip-homebrew passed; not setting HOMEBREW_TAP_TOKEN.${RESET}"
else
    say "A fine-grained or classic PAT scoped to the homebrew-tap repo lets the"
    say "release workflow auto-update the cask. Skip if you don't have a tap yet."
    printf '%sSet HOMEBREW_TAP_TOKEN now?%s [y/N] ' "$BOLD" "$RESET"
    read -r ANS
    case "$ANS" in
        y|Y)
            printf '%sHomebrew Tap GitHub PAT (input hidden):%s ' "$BOLD" "$RESET"
            stty -echo 2>/dev/null || true
            read -r HOMEBREW_PAT
            stty echo 2>/dev/null || true
            printf '\n'
            if [ -n "$HOMEBREW_PAT" ]; then
                printf '%s' "$HOMEBREW_PAT" | push_secret "HOMEBREW_TAP_TOKEN" "SET-FROM-INPUT"
                HOMEBREW_DECISION="set"
            else
                warn "Empty value — not setting HOMEBREW_TAP_TOKEN."
            fi
            ;;
        *)
            say "Skipping Homebrew. The Update-Homebrew-Cask step will be a no-op."
            ;;
    esac
fi

if [ "$HOMEBREW_DECISION" = "skip" ]; then
    if has_secret "HOMEBREW_TAP_TOKEN"; then
        # Leave any existing value alone; record it as REUSED so the user
        # knows it's still wired up.
        record "HOMEBREW_TAP_TOKEN" "REUSED (existing, untouched)"
    else
        record "HOMEBREW_TAP_TOKEN" "SKIPPED"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
EXPECTED=(
    MACOS_KEYCHAIN_PASSWORD
    SPARKLE_PRIVATE_KEY
    MACOS_CERTIFICATE_P12_BASE64
    MACOS_CERTIFICATE_P12_PASSWORD
    MACOS_NOTARY_ISSUER_ID
    MACOS_NOTARY_KEY_ID
    MACOS_NOTARY_KEY_P8_BASE64
    HOMEBREW_TAP_TOKEN
)
printf '  %-34s %s\n' "Secret" "Status"
printf '  %-34s %s\n' "------" "------"
for name in "${EXPECTED[@]}"; do
    line=$(printf '%s' "$SUMMARY" | grep -E "^${name}\|" | tail -1 || true)
    status=${line#*|}
    [ -z "$status" ] && status="(not touched)"
    printf '  %-34s %s\n' "$name" "$status"
done

echo
ok "Bootstrap complete. The release workflow now has every secret it expects."
say "Next step (covered by the follow-up validation task): create + push a v*.*.* tag."
