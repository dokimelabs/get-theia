#!/bin/sh
# get-theia — the theia installer for macOS and Linux.
#   curl -fsSL https://dokimelabs.github.io/get-theia/install.sh | sh
#
# Releases are private. The installer asks the release gate for a device
# code, you sign in with Google, GitHub or Microsoft in a browser, and once
# your identity is on the allowlist the gate hands back a short-lived link
# to the archive. The archive is sha256-verified, unpacked into its own
# versioned directory, run once (a broken build never takes the `theia`
# name), and only then becomes `current`; ~/.local/bin/theia points at it.
# The sign-in also leaves an install credential in $THEIA_HOME/.credentials.json
# (0600, the "install" key): the next run, and `theia update`, trade it for a
# link without a browser for as long as the identity stays on the allowlist.
#
#   THEIA_VERSION=<x.y.z>   install an exact release (default: the latest)
#   THEIA_INSTALL_DIR=<dir> where the `theia` command goes (~/.local/bin)
#   THEIA_HOME=<dir>        where releases live (~/.local/share/theia)
#   THEIA_AUTH_URL=<url>    the release gate (default below)
#   THEIA_NO_MODIFY_PATH=1  never touch shell profiles
#   THEIA_SIGN_IN=1         sign in again even with a saved credential
#
# POSIX sh; idempotent; reinstalling a version replaces it in place.
set -eu

AUTH_URL="${THEIA_AUTH_URL:-https://get-theia.dokimelabs.workers.dev}"
VERSION="${THEIA_VERSION:-latest}"
BIN_DIR="${THEIA_INSTALL_DIR:-$HOME/.local/bin}"
THEIA_ROOT="${THEIA_HOME:-$HOME/.local/share/theia}"
RELEASES_DIR="$THEIA_ROOT/releases"
CURRENT_LINK="$THEIA_ROOT/current"
LOCK_DIR="$THEIA_ROOT/install.lock.d"
CRED_FILE="$THEIA_ROOT/.credentials.json"
BIN_PATH="$BIN_DIR/theia"
tmp_dir=""
staging=""
dl_pid=""

step() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	[ -n "$dl_pid" ] && kill "$dl_pid" 2>/dev/null
	[ -n "$tmp_dir" ] && rm -rf "$tmp_dir"
	[ -n "$staging" ] && rm -rf "$staging"
	rmdir "$LOCK_DIR" 2>/dev/null || true
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

# json_field <json> <key>: a top-level string or number from the gate's
# flat JSON answers (no jq dependency).
json_field() {
	printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p"
}

detect_platform() {
	case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=darwin ;;
	*) die "unsupported OS $(uname -s); on Windows run: irm https://dokimelabs.github.io/get-theia/install.ps1 | iex" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	arm64 | aarch64) arch=arm64 ;;
	*) die "unsupported architecture $(uname -m)" ;;
	esac
	# Rosetta: an Intel shell on Apple silicon still gets the native build.
	if [ "$os" = darwin ] && [ "$arch" = amd64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
		arch=arm64
	fi
}

validate_version() {
	[ "$VERSION" = latest ] && return
	VERSION="${VERSION#v}"
	printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || die "THEIA_VERSION must look like 1.2.3, got '$VERSION'"
}

# post_json <path> <body>: the gate's JSON answer, error statuses included
# (it answers "authorization_pending" with a 400, as RFC 8628 has it).
post_json() { curl -sS --connect-timeout 10 --max-time 30 -X POST -H 'content-type: application/json' -d "$2" "$AUTH_URL$1" 2>/dev/null || true; }

# sign_in runs the device flow and sets version, asset, sha256 and url.
sign_in() {
	answer=$(post_json /device/code "{\"os\":\"$os\",\"arch\":\"$arch\",\"version\":\"$VERSION\"}")
	device_code=$(json_field "$answer" device_code)
	[ -n "$device_code" ] || die "the release gate did not answer ($(json_field "$answer" error_description))"
	user_code=$(json_field "$answer" user_code)
	verify=$(json_field "$answer" verification_uri)
	interval=$(json_field "$answer" interval)
	expires=$(json_field "$answer" expires_in)
	printf '\n  Sign in to download theia:\n\n    %s\n\n  and enter the code  %s\n\n' "$verify" "$user_code"
	if [ -t 1 ] && [ -z "${SSH_CONNECTION:-}" ]; then
		# In the background: xdg-open starting a browser that was not
		# running waits for it to exit, and the polling must not. Only
		# macOS's open is the opener (on Debian `open` is openvt).
		opener=xdg-open
		[ "$os" = darwin ] && opener=open
		if command -v "$opener" >/dev/null 2>&1; then
			"$opener" "$verify?code=$user_code" </dev/null >/dev/null 2>&1 &
		fi
	fi
	waited=0
	while [ "$waited" -lt "${expires:-900}" ]; do
		sleep "${interval:-5}"
		waited=$((waited + ${interval:-5}))
		answer=$(post_json /device/token "{\"device_code\":\"$device_code\"}")
		case "$(json_field "$answer" error)" in
		authorization_pending | "") ;;
		access_denied) die "$(json_field "$answer" error_description) — ask the dokimelabs team for access" ;;
		expired_token) die "the sign-in expired; run the installer again" ;;
		no_release) die "no release for $os/$arch ($(json_field "$answer" error_description))" ;;
		*) die "the release gate answered: $(json_field "$answer" error)" ;;
		esac
		if take_link "$answer"; then
			step "signed in as $(json_field "$answer" identity)"
			return
		fi
	done
	die "the sign-in timed out; run the installer again"
}

# take_link <answer> sets version, asset, sha256 and url from the gate's
# answer and keeps the install credential it carries; fails without a link.
take_link() {
	url=$(json_field "$1" url)
	[ -n "$url" ] || return 1
	version=$(json_field "$1" version)
	asset=$(json_field "$1" asset)
	sha256=$(json_field "$1" sha256)
	token=$(json_field "$1" install_token)
	if [ -n "$token" ]; then
		expires=$(($(date +%s) + $(json_field "$1" install_expires_in)))
		save_credentials "  \"install\": {\"token\": \"$token\", \"identity\": \"$(json_field "$1" identity)\", \"gate\": \"$AUTH_URL\", \"expires_at\": $expires}"
	fi
	return 0
}

# .credentials.json holds one JSON object whose top-level members each sit
# on ONE line ("  \"<key>\": <value>"), so this script can replace its own
# "install" member with sed and keep every other member as it found it;
# theia and the Windows installer read it as ordinary JSON.
#
# save_credentials <member line | "">: the file with "install" replaced
# (or dropped), written 0600 through a rename.
save_credentials() {
	mkdir -p "$THEIA_ROOT"
	others=""
	[ -f "$CRED_FILE" ] && others=$(sed -n '/^  "/{/^  "install":/d;s/,$//;p;}' "$CRED_FILE")
	members=$(printf '%s\n%s\n' "$1" "$others" | sed '/^$/d')
	(
		umask 077
		{
			echo "{"
			[ -n "$members" ] && printf '%s\n' "$members" | sed '$!s/$/,/'
			echo "}"
		} >"$CRED_FILE.tmp.$$"
	) && mv -f "$CRED_FILE.tmp.$$" "$CRED_FILE"
}

# saved_token prints the token of the "install" member ("" = none).
saved_token() {
	[ -f "$CRED_FILE" ] || return 0
	json_field "$(sed -n 's/^  "install": *//p' "$CRED_FILE")" token
}

# refresh trades the saved install credential for a link (no browser);
# it fails, and the device sign-in follows, when there is none or the gate
# no longer accepts it.
refresh() {
	[ "${THEIA_SIGN_IN:-0}" != 1 ] || return 1
	cred=$(saved_token)
	[ -n "$cred" ] || return 1
	answer=$(post_json /install/refresh "{\"install_token\":\"$cred\",\"os\":\"$os\",\"arch\":\"$arch\",\"version\":\"$VERSION\"}")
	case "$(json_field "$answer" error)" in
	"")
		take_link "$answer" || return 1
		step "signed in as $(json_field "$answer" identity) (saved sign-in)"
		return 0
		;;
	access_denied) die "$(json_field "$answer" error_description) — ask the dokimelabs team for access" ;;
	no_release) die "no release for $os/$arch ($(json_field "$answer" error_description))" ;;
	invalid_token)
		warn "the saved sign-in is no longer valid; sign in again"
		save_credentials ""
		return 1
		;;
	*) return 1 ;;
	esac
}

# human <bytes>: 512 B, 3.4 KB, 10.2 MB.
human() {
	awk -v b="$1" 'BEGIN { if (b < 1024) printf "%d B", b; else if (b < 1048576) printf "%.1f KB", b / 1024; else printf "%.1f MB", b / 1048576 }'
}

# clock <seconds>: 7s, 1m05s.
clock() {
	if [ "$1" -lt 60 ]; then printf '%ss' "$1"; else printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); fi
}

# download <url> <file>. On a terminal, one line redrawn in place shows a
# spinner, the elapsed time, what has arrived of the total and what is
# left; the total is the Content-Length curl writes to its header file as
# soon as the headers arrive. Elsewhere the download stays silent.
download() {
	if [ ! -t 2 ]; then
		curl -fsSL --connect-timeout 10 --retry 3 -o "$2" "$1"
		return
	fi
	headers="$tmp_dir/headers"
	: >"$headers"
	curl -fsSL --connect-timeout 10 --retry 3 -D "$headers" -o "$2" "$1" &
	dl_pid=$!
	started=$(date +%s)
	tick=0
	while kill -0 "$dl_pid" 2>/dev/null; do
		got=0
		[ -f "$2" ] && got=$(wc -c <"$2" | tr -d ' ')
		total=$(tr -d '\r' <"$headers" | sed -n 's/^[Cc]ontent-[Ll]ength:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n 1)
		case $((tick % 10)) in
		0) spin='⠋' ;; 1) spin='⠙' ;; 2) spin='⠹' ;; 3) spin='⠸' ;; 4) spin='⠼' ;;
		5) spin='⠴' ;; 6) spin='⠦' ;; 7) spin='⠧' ;; 8) spin='⠇' ;; *) spin='⠏' ;;
		esac
		elapsed=$(clock $(($(date +%s) - started)))
		if [ -n "$total" ] && [ "$total" -gt 0 ]; then
			left=$((total - got))
			[ "$left" -lt 0 ] && left=0
			printf '\r\033[K    %s %s  %s / %s  %s left' "$spin" "$elapsed" "$(human "$got")" "$(human "$total")" "$(human "$left")" >&2
		else
			printf '\r\033[K    %s %s  %s' "$spin" "$elapsed" "$(human "$got")" >&2
		fi
		tick=$((tick + 1))
		sleep 0.1 2>/dev/null || sleep 1
	done
	rc=0
	wait "$dl_pid" || rc=$?
	dl_pid=""
	printf '\r\033[K' >&2
	[ "$rc" -eq 0 ] || return "$rc"
	printf '    %s in %s\n' "$(human "$(wc -c <"$2" | tr -d ' ')")" "$(clock $(($(date +%s) - started)))" >&2
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

acquire_lock() {
	mkdir -p "$THEIA_ROOT"
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		# A lock older than ten minutes is a crashed install, not a live one.
		if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
			rmdir "$LOCK_DIR" 2>/dev/null || true
			mkdir "$LOCK_DIR" || die "another install is running"
		else
			die "another install is running (remove $LOCK_DIR if it is not)"
		fi
	fi
}

# replace_link <link> <target>: atomic symlink swap via rename. A plain
# `mv new current` would move the new link INTO the directory `current`
# points at, so the rename must not follow the old link: GNU mv -T, BSD
# mv -h; elsewhere remove the old link first.
replace_link() {
	tmp_link="$1.tmp.$$"
	rm -f "$tmp_link"
	ln -s "$2" "$tmp_link"
	mv -fT "$tmp_link" "$1" 2>/dev/null || mv -fh "$tmp_link" "$1" 2>/dev/null || {
		rm -f "$1" && mv -f "$tmp_link" "$1"
	}
}

pick_profile() {
	case "$os:${SHELL:-}" in
	darwin:*/zsh) printf '%s\n' "$HOME/.zprofile" ;;
	darwin:*/bash) printf '%s\n' "$HOME/.bash_profile" ;;
	linux:*/zsh) printf '%s\n' "$HOME/.zshrc" ;;
	linux:*/bash) printf '%s\n' "$HOME/.bashrc" ;;
	*) printf '%s\n' "$HOME/.profile" ;;
	esac
}

# add_to_path keeps one managed block in the shell profile.
add_to_path() {
	case ":$PATH:" in *":$BIN_DIR:"*) return ;; esac
	[ "${THEIA_NO_MODIFY_PATH:-0}" = 1 ] && {
		warn "$BIN_DIR is not on PATH"
		return
	}
	profile=$(pick_profile)
	begin="# >>> theia installer >>>"
	end="# <<< theia installer <<<"
	line="export PATH=\"$BIN_DIR:\$PATH\""
	if [ -f "$profile" ] && grep -qF "$begin" "$profile"; then
		awk -v b="$begin" -v e="$end" -v l="$line" '$0==b{print b; print l; print e; skip=1; next} skip&&$0==e{skip=0; next} !skip' "$profile" >"$tmp_dir/profile" && cat "$tmp_dir/profile" >"$profile"
	else
		printf '\n%s\n%s\n%s\n' "$begin" "$line" "$end" >>"$profile"
	fi
	path_note="restart your shell, or run: export PATH=\"$BIN_DIR:\$PATH\""
}

main() {
	require_command curl
	require_command tar
	require_command uname
	detect_platform
	validate_version
	tmp_dir=$(mktemp -d)
	# EXIT cleans up; a signal only exits (a trap that merely cleaned up
	# would let the script carry on after Ctrl-C).
	trap cleanup EXIT
	trap 'exit 130' INT TERM
	step "theia for $os/$arch"
	previous=""
	[ -L "$CURRENT_LINK" ] && previous=$(basename "$(readlink "$CURRENT_LINK")")
	refresh || sign_in
	if [ -n "$previous" ] && [ "$previous" != "$version" ]; then
		step "updating theia $previous → $version"
	elif [ -n "$previous" ]; then
		step "theia $version is already installed; installing it again"
	fi
	step "downloading $asset"
	download "$url" "$tmp_dir/$asset" || die "download failed"
	got=$(sha256_of "$tmp_dir/$asset")
	[ "$got" = "$sha256" ] || die "checksum mismatch for $asset (want $sha256, got $got)"
	acquire_lock
	release_dir="$RELEASES_DIR/$version"
	staging="$RELEASES_DIR/.staging.$$"
	rm -rf "$staging" && mkdir -p "$staging"
	tar -xzf "$tmp_dir/$asset" -C "$staging" || die "could not unpack $asset"
	[ -x "$staging/theia" ] || die "$asset has no theia binary"
	"$staging/theia" --version >/dev/null 2>&1 || die "the downloaded theia does not run on this machine"
	rm -rf "$release_dir" && mv "$staging" "$release_dir"
	replace_link "$CURRENT_LINK" "$release_dir"
	mkdir -p "$BIN_DIR"
	replace_link "$BIN_PATH" "$CURRENT_LINK/theia"
	"$BIN_PATH" --version >/dev/null 2>&1 || die "$BIN_PATH does not run after install"
	path_note=""
	add_to_path
	step "installed theia $version → $BIN_PATH"
	[ -n "$path_note" ] && printf '    %s\n' "$path_note"
	printf '    start with: theia\n'
}

main "$@"
