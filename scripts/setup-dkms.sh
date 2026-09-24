#!/bin/bash
# Minisforum N5 IT5571 — DKMS Install Script (Debian/Ubuntu/Proxmox · Fedora/RHEL)
#
# Run as root: sudo ./setup-dkms.sh [--enable-write] [VERSION]
#
#   --enable-write   Load with experimental_write=1 (PWM control enabled).
#                    Default: read-only sensors, no PWM writes.
#
#   VERSION          DKMS package version (default: 0.3.0).
#                    install.sh passes the release version so the DKMS
#                    package name matches the release tarball.
#
# Missing build dependencies (compiler + matching kernel headers) and the
# dkms package are installed automatically for the detected distro.
# After running, driver auto-rebuilds on every kernel update.

set -euo pipefail

# Shared distro/kernel dependency resolution.
. "$(dirname "${BASH_SOURCE[0]}")/lib/kernel-deps.sh"

DRIVER_NAME="minisforum-n5-it5571"
DRIVER_VERSION="${DRIVER_VERSION:-0.3.0}"   # keep in sync with VERSION in install.sh
ENABLE_WRITE=0

# Parse arguments: --enable-write flag or positional VERSION
for arg in "$@"; do
    case "$arg" in
        --enable-write) ENABLE_WRITE=1 ;;
        -*)             echo "unknown option: $arg" >&2; exit 1 ;;
        *)              DRIVER_VERSION="$arg" ;;
    esac
done

# ---------------------------------------------------------------------------
#  Locate driver source (Makefile + .c) relative to this script.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIVER_SRC="${REPO_ROOT}/driver-prototype"

if [ ! -f "${DRIVER_SRC}/minisforum_n5_it5571.c" ] || [ ! -f "${DRIVER_SRC}/Makefile" ]; then
    echo "error: driver source not found at ${DRIVER_SRC}" >&2
    echo "this script must be run from inside the repository (scripts/setup-dkms.sh)" >&2
    exit 1
fi

DKMS_DIR="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

# ---------------------------------------------------------------------------
#  Root check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

# ---------------------------------------------------------------------------
#  Dependencies: compiler + kernel headers (current and for future upgrades), dkms
# ---------------------------------------------------------------------------
echo "Ensuring build dependencies and dkms..."
ensure_dkms

# ---------------------------------------------------------------------------
#  Populate DKMS tree with driver source
# ---------------------------------------------------------------------------
echo "Creating DKMS tree at ${DKMS_DIR}..."
mkdir -p "${DKMS_DIR}"

echo "Copying driver source from ${DRIVER_SRC}..."
cp -r "${DRIVER_SRC}"/* "${DKMS_DIR}/"

echo "Writing dkms.conf..."
cat > "${DKMS_DIR}/dkms.conf" <<EOF
PACKAGE_NAME="${DRIVER_NAME}"
PACKAGE_VERSION="${DRIVER_VERSION}"
BUILT_MODULE_NAME[0]="minisforum_n5_it5571"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
EOF

# ---------------------------------------------------------------------------
#  DKMS registration (idempotent: remove stale entry first)
# ---------------------------------------------------------------------------
echo "Registering with DKMS..."
dkms remove -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}" --all 2>/dev/null || true
dkms add -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

echo "Building module for kernel $(uname -r)..."
dkms build -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

echo "Installing module..."
dkms install -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

# ---------------------------------------------------------------------------
#  Load module and persist config
# ---------------------------------------------------------------------------
if [ "$ENABLE_WRITE" -eq 1 ]; then
    echo "Loading module with experimental_write=1 (PWM enabled)..."
    modprobe minisforum_n5_it5571 experimental_write=1
    echo "options minisforum_n5_it5571 experimental_write=1" > /etc/modprobe.d/minisforum-n5.conf
else
    echo "Loading module (read-only sensors, no PWM writes)..."
    modprobe minisforum_n5_it5571
    rm -f /etc/modprobe.d/minisforum-n5.conf
fi

echo "minisforum_n5_it5571" > /etc/modules-load.d/minisforum-n5.conf

echo ""
echo "Done. DKMS status:"
dkms status

echo ""
echo "Module loaded:"
lsmod | grep minisforum_n5_it5571 || true

echo ""
echo "To verify sensors work:"
echo "  sensors"
