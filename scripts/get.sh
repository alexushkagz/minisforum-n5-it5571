#!/usr/bin/env bash
#
# Minisforum N5 (IT5571) fan driver -- downloader / entrypoint
#
# Downloads the release archive, verifies its SHA-256, unpacks it, and runs
# the installer as root. Inspect get.sh and install.sh before trusting it.
#
# Usage:
#   sudo bash -c "$(curl -fsSL https://github.com/alexushkagz/minisforum-n5-it5571/releases/latest/download/get.sh)" -- --persistent
#
# Any install.sh flag works: --test, --persistent, --dkms, --uninstall, --help.
#
# ============================================================================
#  CONFIG -- a published release replaces these placeholders.
# ============================================================================
VERSION="<REPLACE: release version, e.g. 0.3.0>"
SHA256="<REPLACE: 64 hex chars from: sha256sum minisforum-n5-it5571-VERSION.tar.gz>"

GH_USER="alexushkagz"
GH_REPO="minisforum-n5-it5571"

MODULE="minisforum_n5_it5571"
# ============================================================================

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# Intentionally self-contained: it runs as root before any archive exists, so
# there is nothing local to source. The empty case is listed separately because
# a pattern like *"") collapses to *, which would match every value.
UNCONFIGURED="is not configured; use a published get.sh, or run scripts/install.sh from a clone"
case "$SHA256" in
  "" | *"<REPLACE"*)  die "SHA256 ${UNCONFIGURED}" ;;
esac
case "$VERSION" in
  "" | *"<REPLACE"*)  die "VERSION ${UNCONFIGURED}" ;;
esac

TARBALL="minisforum-n5-it5571-${VERSION}.tar.gz"
URL="https://github.com/${GH_USER}/${GH_REPO}/releases/download/v${VERSION}/${TARBALL}"

WORK="$(mktemp -d)"
# Not exec: exec would replace this shell and its EXIT trap would never run,
# leaving the temp dir behind. Call install.sh normally and pass on its status.
trap 'rm -rf "$WORK"' EXIT

echo "downloading ${URL}" >&2
curl -fsSL "$URL" -o "${WORK}/${TARBALL}" \
  || die "download failed -- is the network up, and has release v${VERSION} been published?"

if ! printf '%s  %s\n' "$SHA256" "${WORK}/${TARBALL}" | sha256sum --check - >/dev/null 2>&1; then
  actual="$(sha256sum "${WORK}/${TARBALL}" | cut -d' ' -f1)"
  die "checksum mismatch -- expected ${SHA256}, got ${actual}; re-run, or re-download if this keeps happening"
fi
echo "checksum OK" >&2

tar -xzf "${WORK}/${TARBALL}" -C "$WORK"

# The folder name inside the archive depends on how it was built, so it is
# discovered rather than assumed. Collect missing paths so an incomplete
# archive fails here with an actionable error.
REQUIRED="
driver-prototype/${MODULE}.c
driver-prototype/Makefile
scripts/install.sh
scripts/setup-dkms.sh
scripts/uninstall.sh
scripts/lib/kernel-deps.sh
"

SRCDIR=""
for cand in "$WORK"/*/; do
  [ -d "$cand" ] || continue
  missing=""
  for want in $REQUIRED; do
    [ -f "${cand}${want}" ] || missing="${missing} ${want}"
  done
  if [ -z "$missing" ]; then
    SRCDIR="${cand%/}"
    break
  fi
  [ -n "$SRCDIR" ] || LAST_MISSING="$missing"
done

[ -n "$SRCDIR" ] || die "${TARBALL} is incomplete -- missing:${LAST_MISSING:- a top-level source folder}"

bash "${SRCDIR}/scripts/install.sh" "$@"
