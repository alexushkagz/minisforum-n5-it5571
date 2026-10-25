#!/bin/bash
# Minisforum N5 IT5571 — DKMS Install Script (Debian/Ubuntu/Proxmox · Fedora/RHEL)
#
# Run as root: sudo ./setup-dkms.sh [--enable-write] [VERSION]
#
#   --enable-write   Load with enable_write=1 (PWM control enabled).
#                    Default: read-only sensors, no PWM writes.
#
#   VERSION          optional DKMS package version. Defaults to the version
#                    declared by MODULE_VERSION in the driver source.
#
# Missing build dependencies (compiler + matching kernel headers) and the
# dkms package are installed automatically for the detected distro.
# After running, driver auto-rebuilds on every kernel update.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/kernel-deps.sh"

DRIVER_NAME="minisforum-n5-it5571"
DRIVER_VERSION="${DRIVER_VERSION:-}"
ENABLE_WRITE=0

for arg in "$@"; do
    case "$arg" in
        --enable-write) ENABLE_WRITE=1 ;;
        -*)             echo "unknown option: $arg" >&2; exit 1 ;;
        *)              DRIVER_VERSION="$arg" ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIVER_SRC="${REPO_ROOT}/driver-prototype"

if [ ! -f "${DRIVER_SRC}/minisforum_n5_it5571.c" ] || [ ! -f "${DRIVER_SRC}/Makefile" ]; then
    echo "error: driver source not found at ${DRIVER_SRC}" >&2
    echo "this script must be run from inside the repository (scripts/setup-dkms.sh)" >&2
    exit 1
fi

[ -n "$DRIVER_VERSION" ] || DRIVER_VERSION="$(driver_version "${DRIVER_SRC}/minisforum_n5_it5571.c")"

DKMS_DIR="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

echo "Ensuring build dependencies and dkms..."
ensure_dkms

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

echo "Registering with DKMS..."
dkms remove -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}" --all 2>/dev/null || true
dkms add -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

echo "Building module for kernel $(uname -r)..."
dkms build -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

echo "Installing module..."
dkms install -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

if [ "$ENABLE_WRITE" -eq 1 ]; then
    echo "Loading module with enable_write=1 (PWM enabled)..."
    modprobe minisforum_n5_it5571 enable_write=1
    echo "options minisforum_n5_it5571 enable_write=1" > /etc/modprobe.d/minisforum-n5.conf
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
