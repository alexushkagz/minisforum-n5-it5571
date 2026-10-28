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
    die "driver source not found at ${DRIVER_SRC} -- this script must be run from inside the repository (scripts/setup-dkms.sh)"
fi

DRIVER_VERSION="$(driver_version "${DRIVER_SRC}/${MODULE}.c")"

DKMS_DIR="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

need_root

ensure_dkms

banner "DKMS registration"
mkdir -p "${DKMS_DIR}"
cp "${DRIVER_SRC}/${MODULE}.c" "${DRIVER_SRC}/Makefile" "${DKMS_DIR}/"
cat > "${DKMS_DIR}/dkms.conf" <<EOF
PACKAGE_NAME="${DRIVER_NAME}"
PACKAGE_VERSION="${DRIVER_VERSION}"
BUILT_MODULE_NAME[0]="${MODULE}"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
EOF

registered="$(dkms_registered_versions)" || die "dkms status failed; fix dkms and rerun"
if grep -qxF "${DRIVER_VERSION}" <<< "$registered"; then
    dkms remove -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}" --all \
        || die "could not remove the existing DKMS registration of ${DRIVER_NAME} ${DRIVER_VERSION} (unload the module and retry)"
fi
dkms add -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

banner "Building and installing for kernel $(uname -r)"
dkms build -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"
dkms install -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

banner "Loading the module"
if [ "$ENABLE_WRITE" -eq 1 ]; then
    echo "options ${MODULE} enable_write=1" > "$MODPROBE_CONF"
    load_result="loaded with PWM writes ENABLED (enable_write=1)"
else
    rm -f "$MODPROBE_CONF"
    load_result="loaded (read-only sensors, no PWM writes)"
fi

reload_prepare
modprobe "$MODULE" \
    || die "load failed -- verify with: dmesg | grep ${MODULE}; the DKMS install itself succeeded and stays registered"

echo "$MODULE" > "$MODULES_LOAD_CONF"

summary_add OK "DKMS: ${DRIVER_NAME} ${DRIVER_VERSION}, rebuilt automatically on every kernel update"
summary_add OK "${load_result}"
summary_add NEXT "check temperatures and RPM: sensors"
summary_print

