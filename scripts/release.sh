#!/usr/bin/env bash
#
# Release helper for the Minisforum N5 (IT5571) driver.
#
# Builds the release tarball the installer downloads, from an existing git ref
# (the vX.Y.Z tag), and prints the SHA256 to paste into scripts/install.sh
# CONFIG as well as the `gh release` commands to publish it.
#
# It never pushes tags or uploads anything -- publishing stays manual.
#
# Usage:
#   scripts/release.sh [--ref <gitref>] [TAG]
#     TAG   tag to release (default: v0.3.0, same value as VERSION in install.sh)
#     --ref git ref to archive (default: the TAG). Use --ref HEAD to
#           smoke-test the packaging without creating a tag.
#
# Output: dist/minisforum-n5-it5571-<VERSION>.tar.gz

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAG=""
REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      [ $# -ge 2 ] || { echo "error: --ref needs a value" >&2; exit 1; }
      REF="$2"; shift 2 ;;
    --ref=*) REF="${1#--ref=}"; shift ;;
    --[a-z]*|-*) echo "unknown option: $1" >&2; exit 1 ;;
    *) TAG="$1"; shift ;;
  esac
done

[ -n "$TAG" ] || TAG="v0.3.0"

VERSION="${TAG#v}"
REF="${REF:-$TAG}"
DIST_DIR="${REPO_ROOT}/dist"
TARBALL="minisforum-n5-it5571-${VERSION}.tar.gz"
PREFIX="minisforum-n5-it5571-${VERSION}/"

git rev-parse --verify "${REF}^{commit}" >/dev/null \
  || { echo "error: git ref '${REF}' not found" >&2; exit 1; }

echo "archiving ${REF} -> ${DIST_DIR}/${TARBALL} (prefix ${PREFIX})"
mkdir -p "$DIST_DIR"
git archive --format=tar.gz --prefix="$PREFIX" -o "${DIST_DIR}/${TARBALL}" "$REF"

LISTING="${DIST_DIR}/.listing-${TARBALL%.tar.gz}.txt"
tar -tzf "${DIST_DIR}/${TARBALL}" > "$LISTING"
grep -q "^${PREFIX}scripts/lib/kernel-deps.sh$" "$LISTING" \
  || { rm -f "$LISTING"; echo "error: tarball is missing scripts/lib/kernel-deps.sh (bad layout?)" >&2; exit 1; }
grep -q "^${PREFIX}driver-prototype/minisforum_n5_it5571.c$" "$LISTING" \
  || { rm -f "$LISTING"; echo "error: tarball is missing driver-prototype/minisforum_n5_it5571.c (bad layout?)" >&2; exit 1; }
rm -f "$LISTING"

echo ""
echo "tarball checksum -- paste into scripts/install.sh CONFIG:"
echo "   SHA256=\"$(sha256sum "${DIST_DIR}/${TARBALL}" | awk '{print $1}')\""
echo ""
echo "upload -- from the git root:"
echo "   gh release create ${TAG} ${DIST_DIR}/${TARBALL} --title \"${TAG}\""
echo "   gh release upload ${TAG} scripts/install.sh"
echo ""
echo "done: ${DIST_DIR}/${TARBALL}"