#!/usr/bin/env bash
#
# Release helper for the Minisforum N5 (IT5571) driver.
#
# Builds the source archive, its checksum, and a get.sh with the version and
# checksum filled in. Everything is read from the tagged commit, never from the
# working tree, so uncommitted changes are ignored.
#
# It never pushes tags or uploads anything -- publishing stays manual.
#
# Usage:
#   scripts/release.sh [TAG] [--ref REF]
#     TAG   tag to release (default: v<MODULE_VERSION at HEAD>)
#     --ref REF   build from this ref instead of the tag; the tag must still
#                 match the version in REF (e.g. --ref HEAD for a smoke test)

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

if [ -z "$TAG" ]; then
  head_src="$(git show "HEAD:${DRIVER_SRC}")" || die "cannot read ${DRIVER_SRC} at HEAD"
  TAG="v$(printf '%s\n' "$head_src" | driver_version /dev/stdin)"
fi
REF="${REF:-$TAG}"

if ! git rev-parse --verify "${REF}^{commit}" >/dev/null 2>&1; then
  if [ "$REF" = "$TAG" ]; then
    die "tag ${TAG} not found -- create it first: git tag -a ${TAG} -m \"${TAG}: ...\""
  fi
  die "git ref '${REF}' not found"
fi

TMP_SRC="$(mktemp "${TMPDIR:-/tmp}/n5-driver-src.XXXXXX")"
trap 'rm -f "$TMP_SRC"' EXIT
git show "${REF}:${DRIVER_SRC}" > "$TMP_SRC" \
  || die "cannot read ${DRIVER_SRC} at ${REF}"
VERSION="$(driver_version "$TMP_SRC")"

if [ "$TAG" != "v${VERSION}" ]; then
  die "tag ${TAG} does not match MODULE_VERSION ${VERSION} in ${DRIVER_SRC} at ${REF} -- fix one of them before releasing"
fi

DIST_DIR="${REPO_ROOT}/dist"
TARBALL="minisforum-n5-it5571-${VERSION}.tar.gz"
PREFIX="minisforum-n5-it5571-${VERSION}/"

mkdir -p "$DIST_DIR"

echo "archiving ${REF} -> ${DIST_DIR}/${TARBALL}"
git archive --format=tar.gz --prefix="$PREFIX" -o "${DIST_DIR}/${TARBALL}" "$REF"

# The archive must match what get.sh and the installer expect; .gitattributes
# controls it.
LISTING="$(tar -tzf "${DIST_DIR}/${TARBALL}")"
for want in driver-prototype/minisforum_n5_it5571.c driver-prototype/Makefile \
            scripts/install.sh scripts/setup-dkms.sh scripts/uninstall.sh \
            scripts/lib/common.sh scripts/lib/kernel-deps.sh; do
  printf '%s\n' "$LISTING" | grep -qxF "${PREFIX}${want}" \
    || die "archive is missing ${want} -- check .gitattributes"
done
for banned in scripts/get.sh scripts/release.sh; do
  if printf '%s\n' "$LISTING" | grep -qxF "${PREFIX}${banned}"; then
    die "archive must not contain ${banned} -- check .gitattributes"
  fi
done
if bad="$(printf '%s\n' "$LISTING" | awk -v p="$PREFIX" '{s=p "unraid-legacy"; if (index($0,s)==1 && (length($0)==length(s) || substr($0,length(s)+1,1)=="/")) {print; exit}}')" && [ -n "$bad" ]; then
  die "archive must not contain ${bad} -- check .gitattributes"
fi

SHA="$(sha256sum "${DIST_DIR}/${TARBALL}" | cut -d' ' -f1)"
printf '%s  %s\n' "$SHA" "$TARBALL" > "${DIST_DIR}/${TARBALL}.sha256"

# get.sh is published with the real values substituted, so users never run a
# version that skips verification.
git show "${REF}:scripts/get.sh" | sed -e "s|^VERSION=\".*<REPLACE.*|VERSION=\"${VERSION}\"|" \
    -e "s|^SHA256=\".*<REPLACE.*|SHA256=\"${SHA}\"|" \
    > "${DIST_DIR}/get.sh"
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
