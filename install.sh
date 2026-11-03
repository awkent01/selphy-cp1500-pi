#!/usr/bin/env bash
# selphy-cp1500-pi: Canon SELPHY CP1500 printing on Raspberry Pi OS Bookworm (arm64).
#
#   sudo ./install.sh                  driver, ipp-usb quirk, and the "selphy" queue
#   sudo ./install.sh --from-source    the same, building gutenprint here
#   ./install.sh --package OUT [--stage DIR] [--upstream FILE]
#                                      maintainers: make the release assets
#
# Options: --queue NAME (default selphy), --no-queue, --root DIR (install into a
# scratch directory instead of /, for testing; no queue, no services).
#
# Safe to run again: anything already right is left alone, and a run with
# nothing to do changes nothing. The driver comes from this repository's
# release, pinned by tag AND sha256; set SELPHY_BASE_URL to fetch the same
# files from somewhere else (they are still checked against the pins).
#
# This script is MIT (see LICENSE). The gutenprint it installs is
# GPL-2.0-or-later; see NOTICE.md.
set -euo pipefail

INSTALLER_TAG="v5.3.5-2"      # this script's release
VERSION="5.3.5-1"             # the driver package's, unchanged since v5.3.5-1
TAG="v$VERSION"               # the release that carries the package
REPO_URL="https://github.com/awkent01/selphy-cp1500-pi"
BASE_URL="${SELPHY_BASE_URL:-$REPO_URL/releases/download/$TAG}"
PKG_NAME="selphy-cp1500-pi-$VERSION-bookworm-arm64"
PKG="$PKG_NAME.tar.xz"
PKG_SHA256="7f2859f12b8add9123e459930ed1490456108438d4b654f583c1b7d3cab17fbf"
UPSTREAM="gutenprint-5.3.5.tar.xz"
UPSTREAM_SHA256="f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70"
UPSTREAM_URL="https://downloads.sourceforge.net/gimp-print/$UPSTREAM"
MODEL="gutenprint.5.3://canon-cp1500/expert"
MODEL_DESC="Canon SELPHY CP1500 - CUPS+Gutenprint v5.3.5"
URI_PREFIX="gutenprint53+usb://canon-cp1500/"
QUIRK="/etc/ipp-usb/quirks/selphy-cp1500.conf"
STATE_DIR="/usr/local/share/selphy-cp1500-pi"
SOURCE_DATE_EPOCH=1793577600          # 2026-11-02T00:00:00Z: reproducible tarballs
CONFIGURE_FLAGS=(
  --prefix=/usr/local --with-cups=/usr --disable-nls
  --disable-static --disable-static-genppd --without-gimp2 --disable-samples
  --disable-test --disable-testpattern --disable-escputil
  --disable-translated-cups-ppds --disable-globalized-cups-ppds
)
BUILD_DEPS=(build-essential pkg-config libcups2-dev libcupsimage2-dev libusb-1.0-0-dev)

ROOT=""            # empty: the real system
CHANGES=0
WORK=""

cleanup() { [[ -n $WORK ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT

log() { printf '%s\n' "$*"; }
note() { printf '  - %s\n' "$*"; CHANGES=$((CHANGES + 1)); }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

quirk_text() {
  cat <<'EOF'
# The SELPHY CP1500 answers ipp-usb's probe with server-error-internal-error,
# and each probe resets the printer. It prints through CUPS and gutenprint's
# USB backend instead. Only this model; ipp-usb stays on for anything else.
[Canon SELPHY CP1500]
  blacklist = true
EOF
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# -- the platform --------------------------------------------------------------

check_platform() {
  local arch codename
  arch=$(dpkg --print-architecture)
  codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)
  [[ $arch == arm64 && $codename == bookworm ]] || die \
    "the prebuilt driver is for Raspberry Pi OS Bookworm on arm64, and this is" \
    "$codename on $arch. Use --from-source to build it here."
}

# -- manifests -------------------------------------------------------------------
# One line per path under the tree, sorted:  TYPE <tab> MODE <tab> VALUE <tab> PATH
#   d  mode  -        /usr/local/lib/gutenprint
#   f  mode  sha256   /usr/local/lib/libgutenprint.so.9.6.0
#   l  -     target   /usr/local/lib/libgutenprint.so

make_manifest() {
  local root=$1 rel p
  while IFS= read -r -d '' p; do
    rel=${p#.}
    [[ $rel =~ [[:space:]] ]] && die "a path with whitespace: '$rel'"
    if [[ -L $root$rel ]]; then
      printf 'l\t-\t%s\t%s\n' "$(readlink "$root$rel")" "$rel"
    elif [[ -d $root$rel ]]; then
      printf 'd\t%s\t-\t%s\n' "$(stat -c %a "$root$rel")" "$rel"
    elif [[ -f $root$rel ]]; then
      printf 'f\t%s\t%s\t%s\n' "$(stat -c %a "$root$rel")" "$(sha256_of "$root$rel")" "$rel"
    else
      die "not a file, link or directory: $rel"
    fi
  done < <(cd "$root" && find . -mindepth 1 -print0 | sort -z)
}

# Is this path, on the target, already exactly what the manifest says?
matches() {
  local type=$1 value=$2 dest=$3
  case $type in
    f) [[ -f $dest && ! -L $dest ]] && [[ $(sha256_of "$dest") == "$value" ]] ;;
    l) [[ -L $dest ]] && [[ $(readlink "$dest") == "$value" ]] ;;
    *) return 1 ;;
  esac
}

# Paths dpkg says belong to an installed package, one per line.
dpkg_owned() {
  (($# == 0)) && return 0
  { dpkg -S "$@" 2>/dev/null || true; } | sed -n 's/^[^:]*: \(\/.*\)$/\1/p' | sort -u
}

# Every reason not to install MANIFEST at ROOT. Nothing is written.
# PREVIOUS is our own last install there (empty if none): its files may be replaced.
check_conflicts() {
  local manifest=$1 previous=${2:-} type mode value path dest
  local -a files=() problems=()
  local -A ours=()
  if [[ -n $previous && -f $previous ]]; then
    while IFS=$'\t' read -r type mode value path; do ours[$path]=1; done < "$previous"
  fi
  while IFS=$'\t' read -r type mode value path; do
    [[ $type == d ]] && continue
    files+=("$path")
    dest=$ROOT$path
    if [[ -e $dest || -L $dest ]] && [[ -z ${ours[$path]:-} ]] && ! matches "$type" "$value" "$dest"; then
      problems+=("$path exists and is not ours")
    fi
  done < "$manifest"
  local owned
  owned=$(dpkg_owned "${files[@]}")
  if [[ -n $owned ]]; then
    while IFS= read -r path; do problems+=("$path belongs to a Debian package"); done <<< "$owned"
  fi
  if ((${#problems[@]})); then
    printf 'ERROR: refusing to install, nothing was written:\n' >&2
    printf '  %s\n' "${problems[@]}" >&2
    return 1
  fi
}

# -- installing a tree -----------------------------------------------------------

install_tree() {
  local src=$1 manifest=$2 type mode value path dest state=$ROOT$STATE_DIR
  check_conflicts "$manifest" "$state/installed.manifest"
  local -a created=()
  while IFS=$'\t' read -r type mode value path; do
    dest=$ROOT$path
    case $type in
      d) if [[ ! -d $dest ]]; then
           mkdir -m "$mode" "$dest"
           created+=("$(printf 'd\t%s\t-\t%s' "$mode" "$path")")
         fi ;;
      f) if ! matches f "$value" "$dest"; then
           install -m "$mode" -T "$src$path" "$dest.selphy-new"
           mv -f "$dest.selphy-new" "$dest"
         fi ;;
      l) matches l "$value" "$dest" || ln -sfn "$value" "$dest" ;;
    esac
  done < "$manifest"
  mkdir -p "$state"
  {
    grep -v '^d' "$manifest" || true
    ((${#created[@]})) && printf '%s\n' "${created[@]}"
  } > "$state/installed.manifest"
  printf '%s\n' "$VERSION" > "$state/version"
  note "installed gutenprint 5.3.5 ($(grep -vc '^d' "$manifest") files) under ${ROOT:-/}"
  if [[ -z $ROOT ]]; then
    ldconfig
    systemctl restart cups
  fi
}

# Already installed by us, and still intact?
ours_installed() {
  local state=$ROOT$STATE_DIR type mode value path
  [[ -f $state/version && $(<"$state/version") == "$VERSION" && -f $state/installed.manifest ]] || return 1
  while IFS=$'\t' read -r type mode value path; do
    [[ $type == d ]] && continue
    matches "$type" "$value" "$ROOT$path" || return 1
  done < "$state/installed.manifest"
}

# The driver installed some other way (a hand build, a distro package).
# Captured, never piped into grep -q: grep stops at the match, lpinfo dies of
# SIGPIPE on the thousands of models after it, and pipefail says "not found".
driver_present() {
  [[ -z $ROOT ]] || return 1
  local models
  models=$(lpinfo -m 2>/dev/null) || true
  grep -qF "$MODEL $MODEL_DESC" <<< "$models"
}

fetch() {
  local name=$1 sha=$2 dest=$3
  log "Fetching $name"
  curl -fsSL --retry 2 -o "$dest" "$BASE_URL/$name" || return 1
  if [[ $(sha256_of "$dest") != "$sha" ]]; then
    printf 'ERROR: %s does not match its pinned sha256; nothing was installed.\n' "$name" >&2
    printf '  expected %s\n  got      %s\n' "$sha" "$(sha256_of "$dest")" >&2
    return 2
  fi
}

install_prebuilt() {
  local work=$1 dir
  fetch "$PKG" "$PKG_SHA256" "$work/$PKG" || die "could not get a verified $PKG"
  tar -xJf "$work/$PKG" -C "$work"
  dir=$work/$PKG_NAME
  diff -q <(make_manifest "$dir/root") "$dir/MANIFEST" >/dev/null \
    || die "the package's files do not match its own MANIFEST"
  install_tree "$dir/root" "$dir/MANIFEST"
}

# -- building --------------------------------------------------------------------

get_upstream() {
  local work=$1 given=${2:-}
  if [[ -n $given ]]; then
    cp "$given" "$work/$UPSTREAM"
  elif ! fetch "$UPSTREAM" "$UPSTREAM_SHA256" "$work/$UPSTREAM"; then
    log "Trying upstream instead"
    curl -fsSL --retry 2 -o "$work/$UPSTREAM" "$UPSTREAM_URL" || die "could not download $UPSTREAM"
  fi
  [[ $(sha256_of "$work/$UPSTREAM") == "$UPSTREAM_SHA256" ]] \
    || die "$UPSTREAM does not match its pinned sha256"
}

# Builds into $work/stage with the flags this repository pins.
build_stage() {
  local work=$1
  tar -xJf "$work/$UPSTREAM" -C "$work"
  (
    cd "$work/gutenprint-5.3.5"
    ./configure "${CONFIGURE_FLAGS[@]}" > "$work/configure.log" 2>&1
    make -j"$(nproc)" > "$work/make.log" 2>&1
    make install DESTDIR="$work/stage" > "$work/install.log" 2>&1
  ) || die "the build failed; see the logs in $work"
}

# The one file `make install` writes about the machine that built it.
scrub_stage() {
  local summary=$1/usr/local/lib/gutenprint/5.3/config.summary
  [[ -f $summary ]] || return 0
  sed -i -E -e 's/^(  Generated at [^ ]+) by .*$/\1/' \
            -e 's/^(    uname -a output: +).*$/\1(removed)/' "$summary"
}

install_from_source() {
  local work=$1
  log "Installing build dependencies: ${BUILD_DEPS[*]}"
  apt-get install -y --no-install-recommends "${BUILD_DEPS[@]}"
  get_upstream "$work"
  build_stage "$work"
  scrub_stage "$work/stage"
  make_manifest "$work/stage" > "$work/MANIFEST"
  install_tree "$work/stage" "$work/MANIFEST"
}

package() {
  local out=$1 stage=${2:-} upstream=${3:-} work dir
  WORK=$(mktemp -d)
  work=$WORK
  mkdir -p "$out"
  get_upstream "$work" "$upstream"
  if [[ -z $stage ]]; then
    build_stage "$work"
    stage=$work/stage
  fi
  dir=$work/pkg/$PKG_NAME
  mkdir -p "$dir"
  cp -a "$stage" "$dir/root"
  scrub_stage "$dir/root"
  local leak
  for leak in "$HOME" "$(hostname)" "by $(id -un)"; do
    if grep -rlF -- "$leak" "$dir/root" >/dev/null; then
      die "the tree still names this machine ('$leak'): $(grep -rlF -- "$leak" "$dir/root" | head -3)"
    fi
  done
  cp "$dir/root/usr/local/share/gutenprint/doc/COPYING" "$dir/COPYING"
  cat > "$dir/NOTICE" <<EOF
gutenprint 5.3.5, built for Raspberry Pi OS Bookworm (arm64) with the configure
flags in install.sh of $REPO_URL ($TAG).

gutenprint is free software under the GNU General Public License, version 2 or
later: see COPYING. Its complete corresponding source is $UPSTREAM, unmodified,
sha256 $UPSTREAM_SHA256, published beside this file in the same release.

One file differs from what 'make install' wrote: usr/local/lib/gutenprint/5.3/
config.summary, with the building user's name and host removed.
EOF
  make_manifest "$dir/root" > "$dir/MANIFEST"
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
      -C "$work/pkg" -cf - "$PKG_NAME" | xz -9 -T1 > "$out/$PKG"
  cp "$dir/MANIFEST" "$out/$PKG_NAME.manifest"
  cp "$work/$UPSTREAM" "$out/$UPSTREAM"
  (cd "$out" && sha256sum "$UPSTREAM" "$PKG" "$PKG_NAME.manifest" > SHA256SUMS)
  log "Release assets in $out:"
  cat "$out/SHA256SUMS"
  [[ $PKG_SHA256 == "$(sha256_of "$out/$PKG")" ]] \
    || warn "PKG_SHA256 in install.sh is not this package's: update it before tagging."
}

# -- the ipp-usb quirk and the queue ----------------------------------------------

ensure_quirk() {
  local dest=$ROOT$QUIRK
  if [[ -f $dest ]] && [[ $(<"$dest") == "$(quirk_text)" ]]; then
    return 0
  fi
  [[ -n $(dpkg_owned "$QUIRK") ]] && die "$QUIRK belongs to a Debian package"
  mkdir -p "$ROOT$STATE_DIR"
  local dir
  for dir in /etc/ipp-usb /etc/ipp-usb/quirks; do
    if [[ ! -d $ROOT$dir ]]; then
      mkdir -m 755 "$ROOT$dir"
      printf 'dir\t%s\n' "$dir" >> "$ROOT$STATE_DIR/extras"
    fi
  done
  quirk_text > "$dest"
  printf 'quirk\t%s\n' "$QUIRK" >> "$ROOT$STATE_DIR/extras"
  note "ipp-usb now leaves the CP1500 alone ($QUIRK)"
  if [[ -z $ROOT ]] && systemctl is-active --quiet ipp-usb; then
    systemctl restart ipp-usb
  fi
}

ensure_queue() {
  local queue=$1 uri options defaults
  if ! lpstat -v "$queue" >/dev/null 2>&1; then
    local devices
    devices=$(lpinfo -v 2>/dev/null) || true
    uri=$(awk -v p="$URI_PREFIX" 'index($2, p) == 1 {print $2; exit}' <<< "$devices")
    if [[ -z $uri ]]; then
      warn "no CP1500 on USB, so no queue yet. Switch it on, plug it in, and run this again."
      return 0
    fi
    lpadmin -p "$queue" -E -v "$uri" -m "$MODEL" -D "Canon SELPHY CP1500"
    mkdir -p "$STATE_DIR"
    printf 'queue\t%s\n' "$queue" >> "$STATE_DIR/extras"
    note "created the queue $queue"
  fi
  options=$(lpoptions -p "$queue" -l)
  defaults=$(lpoptions -p "$queue")
  local -a want=()
  grep -qE '^PageSize/[^:]*:.* \*Postcard( |$)' <<< "$options" || want+=(-o PageSize=Postcard)
  grep -qE '^StpBorderless/[^:]*:.* \*True( |$)' <<< "$options" || want+=(-o StpBorderless=True)
  grep -qw 'printer-is-shared=false' <<< "$defaults" || want+=(-o printer-is-shared=false)
  if ((${#want[@]})); then
    lpadmin -p "$queue" "${want[@]}" 2>&1 | grep -v 'drivers are deprecated' >&2 || true
    note "set $queue: ${want[*]}"
  fi
  local where
  where=$(lpstat -v "$queue" 2>/dev/null) || true
  if ! grep -qF "$URI_PREFIX" <<< "$where"; then
    warn "the queue $queue is not on a CP1500 ($(lpstat -v "$queue")); left as it is"
  fi
}

# -- main --------------------------------------------------------------------------

main() {
  local mode=install from_source=0 queue=selphy out="" stage="" upstream=""
  while (($#)); do
    case $1 in
      --from-source) from_source=1 ;;
      --queue) queue=${2:?}; shift ;;
      --no-queue) queue="" ;;
      --root) ROOT=$(realpath "${2:?}"); shift ;;
      --package) mode=package; out=${2:?}; shift ;;
      --stage) stage=$(realpath "${2:?}"); shift ;;
      --upstream) upstream=$(realpath "${2:?}"); shift ;;
      -h|--help) sed -n '2,19p' "$0"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  if [[ $mode == package ]]; then
    package "$out" "$stage" "$upstream"
    return 0
  fi
  if [[ -z $ROOT ]]; then
    ((EUID == 0)) || die "run it with sudo"
  else
    queue=""                  # a scratch root has no CUPS of its own
  fi
  ((from_source)) || check_platform
  [[ $PKG_SHA256 =~ ^[0-9a-f]{64}$ ]] || ((from_source)) || die "this copy of install.sh has no pinned package checksum"

  WORK=$(mktemp -d)
  local work=$WORK
  log "selphy-cp1500-pi $INSTALLER_TAG (driver package $VERSION)"
  if ours_installed; then
    log "gutenprint 5.3.5: already installed by this script"
  elif driver_present; then
    log "gutenprint 5.3.5: the CP1500 driver is already in CUPS, installed some other way; left alone"
  elif ((from_source)); then
    install_from_source "$work"
  else
    install_prebuilt "$work"
  fi
  ensure_quirk
  [[ -n $queue ]] && ensure_queue "$queue"
  if ((CHANGES)); then
    log "Done: $CHANGES change(s)."
  else
    log "Nothing to do: everything was already in place."
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
