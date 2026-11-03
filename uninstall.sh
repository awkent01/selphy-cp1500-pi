#!/usr/bin/env bash
# selphy-cp1500-pi: remove exactly what install.sh installed.
#
#   sudo ./uninstall.sh            the files in its manifest, the ipp-usb quirk and
#                                  the queue, if install.sh created them
#   ./uninstall.sh --root DIR      the same inside a scratch directory
#
# A file that has changed since it was installed, or that a Debian package now
# claims, is left where it is and named. Nothing install.sh did not create is
# touched: a driver installed some other way stays.
#
# MIT licence (see LICENSE).
set -euo pipefail

STATE_DIR="/usr/local/share/selphy-cp1500-pi"
ROOT=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

main() {
  while (($#)); do
    case $1 in
      --root) ROOT=$(realpath "${2:?}"); shift ;;
      -h|--help) sed -n '2,12p' "$0"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ -n $ROOT ]] || ((EUID == 0)) || die "run it with sudo"
  local state=$ROOT$STATE_DIR manifest type value path dest kind what
  manifest=$state/installed.manifest
  [[ -f $manifest || -f $state/extras ]] || { echo "Nothing installed by selphy-cp1500-pi here."; return 0; }

  if [[ -f $state/extras ]]; then
    while IFS=$'\t' read -r kind what; do
      case $kind in
        queue) if [[ -z $ROOT ]] && lpstat -v "$what" >/dev/null 2>&1; then
                 lpadmin -x "$what" && echo "  - removed the queue $what"
               fi ;;
        quirk) if [[ -f $ROOT$what ]]; then rm -f "$ROOT$what" && echo "  - removed $what"; fi ;;
      esac
    done < "$state/extras"
    # Directories it made for the quirk, deepest first, and only once empty.
    while IFS=$'\t' read -r _ what; do
      rmdir "$ROOT$what" 2>/dev/null || true
    done < <(grep '^dir' "$state/extras" | sort -t$'\t' -k2,2r)
  fi

  local removed=0 kept=0
  if [[ -f $manifest ]]; then
    local owned
    owned=$(cut -f4 "$manifest" | xargs -r dpkg -S 2>/dev/null | sed -n 's/^[^:]*: \(\/.*\)$/\1/p' || true)
    while IFS=$'\t' read -r type _ value path; do
      [[ $type == d ]] && continue
      dest=$ROOT$path
      if grep -qxF -- "$path" <<< "$owned"; then
        warn "$path now belongs to a Debian package; left"; kept=$((kept + 1)); continue
      fi
      case $type in
        f) if [[ -f $dest && ! -L $dest ]]; then
             if [[ $(sha256sum "$dest" | cut -d' ' -f1) == "$value" ]]; then
               rm -f "$dest"; removed=$((removed + 1))
             else
               warn "$path has changed since it was installed; left"; kept=$((kept + 1))
             fi
           fi ;;
        l) if [[ -L $dest && $(readlink "$dest") == "$value" ]]; then
             rm -f "$dest"; removed=$((removed + 1))
           fi ;;
      esac
    done < "$manifest"
  fi
  # Directories install.sh created, deepest first, and only once empty: after
  # its own record, which lives in one of them.
  local -a dirs=()
  [[ -f $manifest ]] && mapfile -t dirs < <(grep '^d' "$manifest" | cut -f4 | sort -r)
  rm -rf "$state"
  for path in "${dirs[@]}"; do
    rmdir "$ROOT$path" 2>/dev/null || true
  done
  if ((kept)); then
    echo "  - removed $removed file(s), left $kept"
  else
    echo "  - removed $removed file(s)"
  fi
  if [[ -z $ROOT ]]; then
    ldconfig
    systemctl restart cups
  fi
}

main "$@"
