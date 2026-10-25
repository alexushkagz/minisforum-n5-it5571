#!/usr/bin/env bash
#
# Release helper for the Minisforum N5 (IT5571) driver.
#
# Builds the source archive, its checksum, and a get.sh with the version and
# checksum filled in. Uses the matching vX.Y.Z tag unless --ref says otherwise.
#
# It never pushes tags or uploads anything -- publishing stays manual.
#
# Usage:
#   scripts/release.sh [TAG]
#     TAG   tag to release (default: read from the driver source)
#     --ref HEAD   archive this ref instead of the tag (smoke test only)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

. "$REPO_ROOT/scripts/lib/common.sh"

TAG=""
REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)   [ $# -ge 2 ] || die "--ref needs a value"; REF="$2"; shift 2 ;;
    --ref=*) REF="${1#--ref=}"; shift ;;
    --[a-z]*|-*) die "unknown option: $1" ;;
    *)       TAG="$1"; shift ;;
  esac
done

DRIVER_SRC="driver-prototype/minisforum_n5_it5571.c"
VERSION="$(driver_version "$DRIVER_SRC")"

# Without an explicit tag, release the version the driver source declares.
[ -n "$TAG" ] || TAG="v${VERSION}"

if [ "$TAG" != "v${VERSION}" ]; then
  die "tag ${TAG} does not match MODULE_VERSION ${VERSION} in ${DRIVER_SRC} -- fix one of them before releasing"
fi

REF="${REF:-$TAG}"
DIST_DIR="${REPO_ROOT}/dist"
TARBALL="minisforum-n5-it5571-${VERSION}.tar.gz"
PREFIX="minisforum-n5-it5571-${VERSION}/"

git rev-parse --verify "${REF}^{commit}" >/dev/null \
  || die "git ref '${REF}' not found"

mkdir -p "$DIST_DIR"

echo "archiving ${REF} -> ${DIST_DIR}/${TARBALL}"
git archive --format=tar.gz --prefix="$PREFIX" -o "${DIST_DIR}/${TARBALL}" "$REF"

SHA="$(sha256sum "${DIST_DIR}/${TARBALL}" | cut -d' ' -f1)"
printf '%s  %s\n' "$SHA" "$TARBALL" > "${DIST_DIR}/${TARBALL}.sha256"

# get.sh is published with the real values substituted, so users never run a
# version that skips verification.
sed -e "s|^VERSION=\".*<REPLACE.*|VERSION=\"${VERSION}\"|" \
    -e "s|^SHA256=\".*<REPLACE.*|SHA256=\"${SHA}\"|" \
    "$REPO_ROOT/scripts/get.sh" > "${DIST_DIR}/get.sh"
chmod +x "${DIST_DIR}/get.sh"

# Reject a silent substitution failure. Only the CONFIG assignments are
# checked: get.sh's guard messages legitimately contain <REPLACE.
if grep -qE '^(VERSION|SHA256)="[^"]*<REPLACE' "${DIST_DIR}/get.sh"; then
  die "get.sh still has an unfilled CONFIG placeholder -- check the VERSION/SHA256 lines in scripts/get.sh"
fi
grep -qx "VERSION=\"${VERSION}\"" "${DIST_DIR}/get.sh" \
  || die "get.sh does not contain the expected VERSION after substitution"
grep -qx "SHA256=\"${SHA}\"" "${DIST_DIR}/get.sh" \
  || die "get.sh does not contain the expected SHA256 after substitution"

echo ""
echo "version:   ${VERSION} (from MODULE_VERSION in ${DRIVER_SRC})"
echo "sha256:    ${SHA}"
echo ""
echo "built:"
echo "   dist/${TARBALL}"
echo "   dist/${TARBALL}.sha256"
echo "   dist/get.sh"
echo ""
echo "publish (from the git root):"
echo "   gh release create ${TAG} dist/${TARBALL} --title \"${TAG}\""
echo "   gh release upload ${TAG} dist/${TARBALL}.sha256 dist/get.sh"
