#!/usr/bin/env bash
# install-remote.sh - Download and install claude-warden from a GitHub release
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash -s -- v0.2.0
#   curl -fsSL ... | bash -s -- v0.2.0 --dry-run

set -euo pipefail

REPO="johnzfitch/claude-warden"
WARDEN_TMPDIR=""
MAX_TARBALL_BYTES=$((50 * 1024 * 1024))  # 50 MB

cleanup() { [[ -n "$WARDEN_TMPDIR" && -d "$WARDEN_TMPDIR" ]] && rm -rf "$WARDEN_TMPDIR"; }
trap cleanup EXIT

# === Colors ===
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

info()  { printf "${GREEN}[+]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
error() { printf "${RED}[x]${RESET} %s\n" "$*" >&2; }

# === Detect download tool ===
if command -v curl &>/dev/null; then
    fetch() { curl -fsSL --max-time 30 "$1"; }
    fetch_to() { curl -fsSL --max-time 60 -o "$2" "$1"; }
elif command -v wget &>/dev/null; then
    fetch() { wget -q --timeout=30 -O- "$1"; }
    fetch_to() { wget -q --timeout=60 -O "$2" "$1"; }
else
    error "Either curl or wget is required."
    exit 1
fi

# === Require tar ===
if ! command -v tar &>/dev/null; then
    error "tar is required but not found."
    exit 1
fi

# === Parse arguments ===
VERSION=""
PASSTHROUGH_ARGS=()

for arg in "$@"; do
    if [[ "$arg" =~ ^v[0-9] ]]; then
        VERSION="$arg"
    else
        PASSTHROUGH_ARGS+=("$arg")
    fi
done

# === Validate version format ===
validate_version() {
    local ver="$1"
    if [[ ! "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]; then
        error "Invalid version format: $ver (expected vX.Y.Z or vX.Y.Z-suffix)"
        exit 1
    fi
}

# === Resolve version ===
if [[ -z "$VERSION" ]]; then
    info "Detecting latest release..."
    RELEASE_JSON=$(fetch "https://api.github.com/repos/$REPO/releases/latest") || {
        error "Failed to fetch release info from GitHub API."
        exit 1
    }
    if command -v jq &>/dev/null; then
        VERSION=$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty')
    else
        # Fallback: grep/sed parsing (jq strongly recommended)
        VERSION=$(printf '%s' "$RELEASE_JSON" \
            | grep '"tag_name"' | head -1 \
            | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/') || true
    fi
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        error "Could not determine latest release. Specify a version: bash install-remote.sh v0.2.0"
        exit 1
    fi
fi

validate_version "$VERSION"
info "Version: $VERSION"

# === Download tarball ===
WARDEN_TMPDIR=$(mktemp -d) || { error "Failed to create temporary directory."; exit 1; }
TARBALL="$WARDEN_TMPDIR/claude-warden-${VERSION}.tar.gz"
TARBALL_URL="https://github.com/$REPO/releases/download/$VERSION/claude-warden-${VERSION}.tar.gz"

info "Downloading $TARBALL_URL"
fetch_to "$TARBALL_URL" "$TARBALL"

if [[ ! -s "$TARBALL" ]]; then
    error "Download failed or tarball is empty."
    exit 1
fi

# === Validate tarball size ===
TARBALL_SIZE=$(wc -c < "$TARBALL")
if (( TARBALL_SIZE > MAX_TARBALL_BYTES )); then
    error "Tarball is ${TARBALL_SIZE} bytes (limit: ${MAX_TARBALL_BYTES}). Aborting."
    exit 1
fi

# === Verify checksum ===
CHECKSUM_URL="https://github.com/$REPO/releases/download/$VERSION/claude-warden-${VERSION}.tar.gz.sha256"
CHECKSUM_FILE="$WARDEN_TMPDIR/checksum.sha256"

if fetch_to "$CHECKSUM_URL" "$CHECKSUM_FILE" 2>/dev/null && [[ -s "$CHECKSUM_FILE" ]]; then
    info "Verifying SHA256 checksum..."
    EXPECTED=$(awk '{print $1}' "$CHECKSUM_FILE")
    if command -v sha256sum &>/dev/null; then
        ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        ACTUAL=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
    else
        error "No sha256sum or shasum found. Cannot verify tarball integrity."
        error "  Linux: apt install coreutils   macOS: shasum is built-in"
        exit 1
    fi
    if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        error "Checksum mismatch! Expected: $EXPECTED Got: $ACTUAL"
        error "The tarball may have been tampered with. Aborting."
        exit 1
    fi
    info "Checksum OK."
else
    error "No checksum file found for this release. Refusing to install unverified tarball."
    exit 1
fi

# === Validate tarball contents ===
TARBALL_LISTING=$(tar tzf "$TARBALL")

# Path traversal: absolute paths, ../ anywhere in path
if printf '%s' "$TARBALL_LISTING" | grep -qE '(^/|/\.\./|^\.\./|/\.\.$|^\.\.$)'; then
    error "Tarball contains absolute or parent-traversal paths. Aborting."
    exit 1
fi

# File count
FILE_COUNT=$(printf '%s' "$TARBALL_LISTING" | wc -l)
if (( FILE_COUNT > 1000 )); then
    error "Tarball contains $FILE_COUNT entries (limit: 1000). Aborting."
    exit 1
fi

# Symlink detection: tar tvzf shows "-> target" for symlinks
if tar tvzf "$TARBALL" | grep -qE ' -> '; then
    error "Tarball contains symlinks. Aborting for security."
    exit 1
fi

# === Extract ===
EXTRACT_DIR="$WARDEN_TMPDIR/claude-warden"
mkdir -p "$EXTRACT_DIR"
tar xzf "$TARBALL" -C "$EXTRACT_DIR"

# === Validate install.sh before executing ===
if [[ ! -f "$EXTRACT_DIR/install.sh" ]]; then
    error "install.sh not found in tarball. The release may be malformed."
    exit 1
fi

if ! head -1 "$EXTRACT_DIR/install.sh" | grep -q '^#!/.*bash'; then
    error "install.sh does not appear to be a bash script. Aborting."
    exit 1
fi

chmod +x "$EXTRACT_DIR/install.sh"
info "Running install.sh --copy ${PASSTHROUGH_ARGS[*]:-}"
bash "$EXTRACT_DIR/install.sh" --copy "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
