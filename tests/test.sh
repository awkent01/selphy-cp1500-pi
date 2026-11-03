#!/usr/bin/env bash
# The installer's tests. Run on an arm64 Bookworm machine with a gutenprint
# DESTDIR stage built with install.sh's flags:
#
#   tests/test.sh STAGE_DIR UPSTREAM_TARBALL
#
# Everything happens in a scratch directory. Nothing is installed on the
# system: the install, re-run, uninstall and refusal cases all use --root.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
GIVEN_STAGE=$(realpath "${1:?stage dir}")
GIVEN_TARBALL=$(realpath "${2:?upstream tarball}")
PASS=0
FAIL=0
ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# shellcheck source=/dev/null
source "$HERE/install.sh"     # its functions and pins; it sets its own EXIT trap
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# -- the package ------------------------------------------------------------------
"$HERE/install.sh" --package "$T/rel" --stage "$GIVEN_STAGE" --upstream "$GIVEN_TARBALL" > "$T/package.log" 2>&1
check "the package is what install.sh pins" \
  test "$(sha256sum "$T/rel/$PKG" | cut -d' ' -f1)" = "$PKG_SHA256"
"$HERE/install.sh" --package "$T/rel2" --stage "$GIVEN_STAGE" --upstream "$GIVEN_TARBALL" > /dev/null 2>&1
check "packaging is reproducible" cmp -s "$T/rel/$PKG" "$T/rel2/$PKG"
check "SHA256SUMS verifies" bash -c "cd '$T/rel' && sha256sum -c --quiet SHA256SUMS"
check "the upstream tarball is untouched" \
  test "$(sha256sum "$T/rel/$UPSTREAM" | cut -d' ' -f1)" = "$UPSTREAM_SHA256"
mkdir "$T/x" && tar -xJf "$T/rel/$PKG" -C "$T/x"
check "the package carries gutenprint's COPYING" test -s "$T/x/$PKG_NAME/COPYING"
check "the package's MANIFEST matches its files" \
  diff -q <(make_manifest "$T/x/$PKG_NAME/root") "$T/x/$PKG_NAME/MANIFEST"
check "nothing in it names the building machine" \
  bash -c "! grep -rlF -e '$HOME' -e '$(hostname)' -e 'by $(id -un)' '$T/x'"
# Only config.summary differs from the stage, and only in those two lines.
make_manifest "$GIVEN_STAGE" > "$T/stage.manifest"
check "only config.summary differs from the stage" \
  diff <(grep -v config.summary "$T/stage.manifest") <(grep -v config.summary "$T/x/$PKG_NAME/MANIFEST")
check "and in config.summary only the builder's user and host" \
  test "$(diff "$GIVEN_STAGE/usr/local/lib/gutenprint/5.3/config.summary" \
               "$T/x/$PKG_NAME/root/usr/local/lib/gutenprint/5.3/config.summary" | grep -c '^[<>]')" = 4

# -- install into a scratch root, from the "release" ----------------------------
export SELPHY_BASE_URL="file://$T/rel"
R=$T/root
mkdir "$R"
"$HERE/install.sh" --root "$R" > "$T/i1.log" 2>&1
check "install: exit 0" grep -q "Done:" "$T/i1.log"
check "install: the tree is the stage's manifest exactly" \
  diff <(grep -v '^d' "$T/x/$PKG_NAME/MANIFEST") \
       <(make_manifest "$R" | grep -v '^d' | grep -v -e "$STATE_DIR" -e "$QUIRK")
check "install: the quirk is in place" test "$(cat "$R$QUIRK")" = "$(quirk_text)"
find "$R" -type f -newer "$T/i1.log" > "$T/newer" || true
before=$(make_manifest "$R" | sha256sum)
"$HERE/install.sh" --root "$R" > "$T/i2.log" 2>&1
check "re-run: nothing to do" grep -q "Nothing to do" "$T/i2.log"
check "re-run: not one byte changed" test "$(make_manifest "$R" | sha256sum)" = "$before"

# -- uninstall removes exactly that ------------------------------------------------
"$HERE/uninstall.sh" --root "$R" > "$T/u.log" 2>&1
check "uninstall: the scratch root is empty again" test -z "$(find "$R" -mindepth 1)"
find "$R" -mindepth 1 | head -5

# -- a file that was there first, and not ours -------------------------------------
R2=$T/root2
mkdir -p "$R2/usr/local/lib"
echo "somebody else's" > "$R2/usr/local/lib/libgutenprint.so.9.6.0"
was=$(make_manifest "$R2")
if "$HERE/install.sh" --root "$R2" > "$T/c.log" 2>&1; then bad "a foreign file stops it"
else
  check "a foreign file stops it, by name" grep -q "libgutenprint.so.9.6.0 exists and is not ours" "$T/c.log"
  check "and nothing was written" test "$(make_manifest "$R2")" = "$was"
fi

# -- the checksum gate ---------------------------------------------------------------
cp -r "$T/rel" "$T/badrel"
printf 'X' | dd of="$T/badrel/$PKG" bs=1 seek=4096 conv=notrunc status=none
R3=$T/root3
mkdir "$R3"
if SELPHY_BASE_URL="file://$T/badrel" "$HERE/install.sh" --root "$R3" > "$T/b.log" 2>&1; then
  bad "a corrupted download is refused"
else
  check "a corrupted download is refused" grep -q "does not match its pinned sha256" "$T/b.log"
  check "and nothing was installed" test -z "$(find "$R3" -mindepth 1)"
fi
if SELPHY_BASE_URL="file://$T/nowhere" "$HERE/install.sh" --root "$R3" > "$T/n.log" 2>&1; then
  bad "no network is an error, not an install"
else
  check "no network is an error, not an install" test -z "$(find "$R3" -mindepth 1)"
fi

# -- dpkg's files are never ours to write ---------------------------------------------
ROOT=$T/root4
mkdir "$ROOT"
printf 'f\t755\t%s\t/usr/bin/lp\n' "$(printf x | sha256sum | cut -d' ' -f1)" > "$T/m"
if check_conflicts "$T/m" "" 2> "$T/d.log"; then bad "a Debian package's file is refused"
else check "a Debian package's file is refused" grep -q "/usr/bin/lp belongs to a Debian package" "$T/d.log"
fi
ROOT=""

# -- the platform gate ------------------------------------------------------------------
# shellcheck disable=SC2317  # called by check_platform
dpkg() {
  if [[ $1 == --print-architecture ]]; then echo amd64; else command dpkg "$@"; fi
}
if (check_platform) 2> "$T/p.log"; then bad "amd64 is refused"
else check "amd64 is refused, pointing at --from-source" grep -q -- "--from-source" "$T/p.log"
fi
unset -f dpkg

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
