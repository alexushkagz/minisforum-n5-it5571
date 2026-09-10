#!/bin/bash
# Minisforum N5 IT5571 — DKMS Auto-Install Script (Proxmox/Debian/Ubuntu)
# Run as root: sudo ./setup-dkms.sh
# After running, driver auto-rebuilds on every kernel update.

set -euo pipefail

DRIVER_NAME="minisforum-n5-it5571"
DRIVER_VERSION="0.2.0"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DKMS_DIR="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

# Detect package manager
if command -v apt-get &>/dev/null; then
    PKG_INSTALL="apt-get update && apt-get install -y"
elif command -v dnf &>/dev/null; then
    PKG_INSTALL="dnf install -y"
elif command -v yum &>/dev/null; then
    PKG_INSTALL="yum install -y"
else
    echo "No supported package manager found (apt/dnf/yum)"
    exit 1
fi

echo "Installing DKMS and kernel headers..."
eval "${PKG_INSTALL} dkms linux-headers-$(uname -r)"

echo "Creating DKMS tree at ${DKMS_DIR}..."
mkdir -p "${DKMS_DIR}"

echo "Copying driver source..."
cp -r "${SRC_DIR}"/* "${DKMS_DIR}/"

echo "Writing dkms.conf..."
cat > "${DKMS_DIR}/dkms.conf" <<EOF
PACKAGE_NAME="${DRIVER_NAME}"
PACKAGE_VERSION="${DRIVER_VERSION}"
BUILT_MODULE_NAME[0]="minisforum_n5_it5571"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
EOF

echo "Registering with DKMS..."
dkms add -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

echo "Building module for kernel $(uname -r)..."
dkms build -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

echo "Installing module..."
dkms install -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

echo "Loading module now..."
modprobe minisforum_n5_it5571 experimental_write=1

echo ""
echo "Done. DKMS status:"
dkms status

echo ""
echo "Module loaded:"
lsmod | grep minisforum_n5_it5571 || true

echo ""
echo "To verify sensors work:"
echo "  sensors"