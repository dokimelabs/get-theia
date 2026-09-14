#!/bin/sh
# get-theia — first-stage installer.
#   curl -fsSL https://dokimelabs.github.io/get-theia/install.sh | sh
#
# Detects OS/arch, asks for a GitHub PAT (releases are hosted in the
# private dokimelabs/theia-releases repository), downloads + sha256-verifies
# a release, installs to ~/.local/share/theia/releases/<v>/, verifies the
# binary RUNS before the PATH symlink flips (a broken artifact never
# captures the name), symlinks ~/.local/bin/theia, seeds the vendor
# deliverables, and writes the PAT into ~/.config/theia/config.yaml.
#
# THEIA_VERSION=<x.y.z> pins an exact release (also the recovery lever
# when a newer release or the self-updater misbehaves — reinstalling any
# version over an existing install is supported and clears that version
# from the launcher cache so a corrupt cached copy cannot resurface).
# The default resolves the LATEST RELEASE, which by GitHub API contract
# never returns a pre-release; -pre builds install only when the exact
# suffixed version is typed. POSIX sh only; idempotent.
set -e

REPO="dokimelabs/theia-releases"
API="https://api.github.com/repos/${REPO}"

log() { printf '%s\n' "$*" >&2; }
die() { log "get-theia: error: $*"; exit 1; }

uname_os() {
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$os" in
    linux) echo linux ;;
    darwin) echo darwin ;;
    cygwin_nt* | mingw* | msys_nt*)
      die "Windows is a planned first-class target; not yet supported" ;;
    *) die "unsupported OS: $os (supported: linux, darwin)" ;;
  esac
}

uname_arch() {
  arch=$(uname -m)
  case "$arch" in
    x86_64 | amd64) echo x86_64 ;;
    aarch64 | arm64) echo aarch64 ;;
    *) die "unsupported architecture: $arch (supported: x86_64, aarch64)" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "need sha256sum or shasum"; fi
}

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

OS=$(uname_os)
ARCH=$(uname_arch)

# Intel Macs are out of the release set (Apple silicon only) — refuse by
# name here rather than 404 at download.
if [ "$OS" = darwin ] && [ "$ARCH" = x86_64 ]; then
  die "Intel macOS (darwin/x86_64) is not supported — releases target darwin/aarch64 (Apple silicon) and linux x86_64/aarch64"
fi

# --- PAT -------------------------------------------------------------
PAT="${THEIA_PAT:-}"
if [ -z "$PAT" ]; then
  if [ -t 0 ]; then
    printf 'GitHub PAT for %s (input hidden): ' "$REPO" >&2
    stty -echo 2>/dev/null || true
    read -r PAT
    stty echo 2>/dev/null || true
    printf '\n' >&2
  elif [ -r /dev/tty ]; then
    printf 'GitHub PAT for %s (input hidden): ' "$REPO" >&2
    stty -echo </dev/tty 2>/dev/null || true
    read -r PAT </dev/tty
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >&2
  fi
fi
[ -n "$PAT" ] || die "no PAT — set THEIA_PAT or run interactively (the releases repo is private)"

auth="Authorization: Bearer ${PAT}"

# --- resolve release (latest, or the THEIA_VERSION pin) --------------
if [ -n "${THEIA_VERSION:-}" ]; then
  want="v${THEIA_VERSION#v}"
  log "resolving pinned release ${want} of ${REPO}…"
  latest_json=$(curl -fsSL -H "$auth" -H 'Accept: application/vnd.github+json' "${API}/releases/tags/${want}") \
    || die "release ${want} not found in ${REPO} (check the version and the PAT)"
else
  log "resolving latest release of ${REPO}…"
  latest_json=$(curl -fsSL -H "$auth" -H 'Accept: application/vnd.github+json' "${API}/releases/latest") \
    || die "cannot reach ${REPO} (check the PAT's repo access and network)"
fi
TAG=$(printf '%s' "$latest_json" | tr ',' '\n' | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$TAG" ] || die "could not parse the release tag"
VER=${TAG#v}
ASSET="theia-${TAG}-${OS}-${ARCH}.tar.gz"
log "latest: ${TAG} → ${ASSET}"

asset_url() {
  # asset API url for a name: grep the release json (portable, no jq dep)
  printf '%s' "$latest_json" | tr '}' '\n' | grep -F "\"name\": \"$1\"" -A0 -B10 \
    | sed -n 's/.*"url": *"\(https:\/\/api\.github\.com\/repos\/[^"]*\/assets\/[0-9]*\)".*/\1/p' | tail -1
}

TARBALL_URL=$(asset_url "$ASSET")
SUMS_URL=$(asset_url "checksums.txt")
[ -n "$TARBALL_URL" ] || die "release ${TAG} carries no asset ${ASSET}"

# --- download + verify ----------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
log "downloading ${ASSET}…"
curl -fsSL -H "$auth" -H 'Accept: application/octet-stream' -o "${TMP}/${ASSET}" "$TARBALL_URL" \
  || die "download failed"
# every release ships checksums.txt; treating its absence as tolerable
# would turn a tampered release into a silent install — hard-require it.
[ -n "$SUMS_URL" ] || die "release ${TAG} carries no checksums.txt — refusing to install unverified"
curl -fsSL -H "$auth" -H 'Accept: application/octet-stream' -o "${TMP}/checksums.txt" "$SUMS_URL" \
  || die "checksums.txt download failed"
want=$(grep -F "$ASSET" "${TMP}/checksums.txt" | awk '{print $1}' | head -1)
[ -n "$want" ] || die "checksums.txt has no entry for ${ASSET}"
got=$(sha256_of "${TMP}/${ASSET}")
[ "$want" = "$got" ] || die "checksum mismatch (want $want, got $got)"
log "sha256 verified"

# --- install ---------------------------------------------------------
# Stage-then-swap: extraction never touches a live STORE (a re-run over a
# subtly broken install REPLACES it wholesale), and the binary must RUN
# before the PATH symlink flips — a dead artifact leaves the previous
# install serving and this script failing loudly.
SHARE="${HOME}/.local/share/theia/releases"
STORE="${SHARE}/${VER}"
BIN_DIR="${HOME}/.local/bin"
STAGE="${SHARE}/.stage-$$"
mkdir -p "$SHARE" "$BIN_DIR"
trap 'rm -rf "$TMP" "$STAGE"' EXIT
mkdir -p "$STAGE"
tar -xzf "${TMP}/${ASSET}" -C "$STAGE" --strip-components=1
chmod +x "${STAGE}/theia"
"${STAGE}/theia" version >/dev/null 2>&1 \
  || die "the downloaded binary does not run on this system — previous install (if any) left untouched"
rm -rf "$STORE"
mv "$STAGE" "$STORE"
ln -sf "${STORE}/theia" "${BIN_DIR}/theia"
log "installed theia ${TAG} → ${STORE}"
log "symlinked ${BIN_DIR}/theia"

# clear this version from the launcher cache: a corrupt cached copy would
# otherwise keep resurfacing through --x-release / self update
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/theia/releases"
rm -rf "${CACHE}/${VER}" "${CACHE}"/.stage-* 2>/dev/null || true

# vendor deliverables (prompts/rules/skills): seed the current symlink from
# the embedded copy when absent or dangling; an auto-updated tree is kept
VENDOR_BASE="${HOME}/.local/share/theia/vendor"
if [ -d "${STORE}/lib/vendor" ]; then
  mkdir -p "$VENDOR_BASE"
  if [ ! -e "${VENDOR_BASE}/current" ]; then
    rm -f "${VENDOR_BASE}/current"
    ln -s "${STORE}/lib/vendor" "${VENDOR_BASE}/current"
    log "vendor deliverables → ${VENDOR_BASE}/current (embedded copy; self update refreshes)"
  fi
fi

# --- user config (merge-preserving: only append missing keys) --------
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/theia"
CFG="${CFG_DIR}/config.yaml"
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG" ]; then
  printf 'github:\n  pat: %s\n' "$PAT" > "$CFG"
  chmod 600 "$CFG"
  log "wrote ${CFG} (mode 0600)"
elif ! grep -q 'pat:' "$CFG" 2>/dev/null; then
  if grep -q '^github:' "$CFG" 2>/dev/null; then
    # a github: section already exists — a shell append would duplicate the
    # top-level key (invalid YAML); the installed binary merges properly.
    log "config exists with a github: section — run: theia setup --pat <token>"
  else
    printf 'github:\n  pat: %s\n' "$PAT" >> "$CFG"
    chmod 600 "$CFG"
    log "appended github.pat to ${CFG}"
  fi
else
  log "kept existing ${CFG} (github.pat already present)"
fi

case ":$PATH:" in
  *":${BIN_DIR}:"*) : ;;
  *) log "NOTE: add ${BIN_DIR} to PATH" ;;
esac

# --- first-run setup offer -------------------------------------------
# When no environment beyond the PAT exists yet and a terminal is
# available, offer the interactive setup (global config + harness
# guidance); workspace init happens in the project dir (bare `theia`).
if [ -r /dev/tty ]; then
  NEEDS_SETUP=0
  grep -q 'apiKey:' "$CFG" 2>/dev/null || NEEDS_SETUP=1
  if [ "$NEEDS_SETUP" = 1 ]; then
    printf 'run interactive setup now? [Y/n] ' >&2
    read -r REPLY </dev/tty || REPLY=n
    case "$REPLY" in
      [Nn]*) log "skipped — run: theia setup --interactive" ;;
      *) "${BIN_DIR}/theia" setup --interactive </dev/tty >/dev/tty 2>&1 || log "setup exited nonzero — run: theia setup --interactive" ;;
    esac
  fi
fi

log ""
log "done — try: theia version && theia doctor; then cd your project and run: theia"
