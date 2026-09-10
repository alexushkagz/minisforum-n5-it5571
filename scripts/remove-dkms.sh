#!/bin/bash
# Minisforum N5 IT5571 — DKMS Removal Script
# Run as root: sudo ./remove-dkms.sh
# Completely removes driver from DKMS and system.

set -euo pipefail

DRIVER_NAME="minisforum-n5-it5571"
DRIVER_VERSION="0.2.0"
DKMS_DIR="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

echo "Unloading module if loaded..."
modprobe -r minisforum_n5_it5571 2>/dev/null || true

echo "Removing from DKMS..."
dkms remove -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}" --all 2>/dev/null || true

echo "Removing DKMS source tree..."
rm -rf "${DKMS_DIR}"

echo "Removing modprobe config if exists..."
rm -f /etc/modprobe.d/minisforum-n5.conf

echo "Removing modules-load config if exists..."
rm -f /etc/modules-load.d/minisforum-n5.conf

echo "Updating module dependencies..."
depmod -a

echo ""
echo "Done. Verify removal:"
dkms status | grep "${DRIVER_NAME}" || echo "  (not found in DKMS - OK)"
lsmod | grep minisforum_n5_it5571 || echo "  (not loaded - OK)"