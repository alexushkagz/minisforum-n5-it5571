#!/usr/bin/env bash
# Minisforum N5 IT5571 — DKMS Install Script (Debian/Ubuntu/Proxmox · Fedora/RHEL)
#
# Run as root: sudo ./setup-dkms.sh [--enable-write]
#
#   --enable-write   Load with enable_write=1 (PWM control enabled).
#                    Default: read-only sensors, no PWM writes.
#
# The DKMS package version is the MODULE_VERSION declared in the driver source.
#
# Missing build dependencies (compiler + matching kernel headers) and the
# dkms package are installed automatically for the detected distro.
# After running, driver auto-rebuilds on every kernel update.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/kernel-deps.sh"

ENABLE_WRITE=0

for arg in "$@"; do
    case "$arg" in
        --enable-write) ENABLE_WRITE=1 ;;
        *)              die "unknown option: $arg (usage: setup-dkms.sh [--enable-write])" ;;
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

DRIVER_VERSION="$(driver_version "${DRIVER_SRC}/${MODULE}.c")"

DKMS_DIR="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

need_root

echo "Ensuring build dependencies and dkms..."
ensure_dkms

echo "Creating DKMS tree at ${DKMS_DIR}..."
mkdir -p "${DKMS_DIR}"

echo "Copying driver source from ${DRIVER_SRC}..."
cp "${DRIVER_SRC}/${MODULE}.c" "${DRIVER_SRC}/Makefile" "${DKMS_DIR}/"

echo "Writing dkms.conf..."
cat > "${DKMS_DIR}/dkms.conf" <<EOF
PACKAGE_NAME="${DRIVER_NAME}"
PACKAGE_VERSION="${DRIVER_VERSION}"
BUILT_MODULE_NAME[0]="${MODULE}"
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
    modprobe "$MODULE" enable_write=1
    echo "options ${MODULE} enable_write=1" > "$MODPROBE_CONF"
else
    echo "Loading module (read-only sensors, no PWM writes)..."
    modprobe "$MODULE"
    rm -f "$MODPROBE_CONF"
fi

echo "$MODULE" > "$MODULES_LOAD_CONF"

echo ""
echo "Done. DKMS status:"
dkms status

echo ""
echo "Module loaded:"
lsmod | grep "$MODULE" || true

echo ""
echo "To verify sensors work:"
echo "  sensors"
