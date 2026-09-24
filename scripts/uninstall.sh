#!/bin/bash
# Minisforum N5 IT5571 — uninstaller
#
# Run as root: sudo ./uninstall.sh          (no arguments)
#
# Undoes any install mode this project provides:
#   --test         unloads the module; nothing else was written to disk
#   --persistent   the above plus /lib/modules/<kernel>/extra/<module>.ko
#   --dkms         the above plus the DKMS registration and its /usr/src tree
#
# In every case the modprobe options and auto-load config files are removed as
# well. All registered DKMS versions are removed, so leftovers from older
# releases go away with the current one.
#
# A module that is in use cannot be unloaded. The script says so and removes
# the files anyway; unload it later with "modprobe -r minisforum_n5_it5571".

set -euo pipefail

DRIVER_NAME="minisforum-n5-it5571"
MODULE="minisforum_n5_it5571"
KVER="$(uname -r)"

warning() { echo "warning: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ $# -gt 0 ]; then
    echo "error: unexpected argument: $1 (this script takes no arguments)" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

# ---------------------------------------------------------------------------
#  Unload the running module. A module in use stays loaded; warn and carry on
#  so the rest of the cleanup still happens.
# ---------------------------------------------------------------------------
status_msg="module was not loaded"
if lsmod | awk '{print $1}' | grep -qx "$MODULE"; then
    if modprobe -r "$MODULE" 2>/dev/null || rmmod "$MODULE" 2>/dev/null; then
        status_msg="unloaded the running module"
    else
        warning "module is in use and stays loaded; removing files/registration anyway"
        echo "  unload later with: modprobe -r ${MODULE}" >&2
        status_msg="module still loaded (in use)"
    fi
fi

# ---------------------------------------------------------------------------
#  DKMS registrations. dkms changed its status format in 3.0: older releases
#  print "name, version, kernel, arch", newer ones "name/version, kernel,
#  arch" -- match both. Every registered version is removed, so leftovers from
#  older releases go away with the current one.
# ---------------------------------------------------------------------------
failed_versions=()
if have dkms; then
    versions="$(dkms status 2>/dev/null | sed -n "s/^${DRIVER_NAME}[/,][[:space:]]*\([0-9][0-9.]*\).*/\1/p" | sort -u || true)"

    if [ -n "$versions" ]; then
        removed=0
        # One version per line; a here-string (not a pipe) keeps $removed in
        # scope for the check below.
        while IFS= read -r version; do
            [ -n "$version" ] || continue
            if dkms remove -m "$DRIVER_NAME" -v "$version" --all >/dev/null 2>&1; then
                removed=1
            else
                failed_versions+=("$version")
            fi
        done <<< "$versions"
        if [ "$removed" -eq 1 ]; then
            status_msg="${status_msg}; removed DKMS registration"
        fi
    fi
fi

# Source trees of removed versions, plus orphans from older releases. A version
# whose removal failed keeps its tree: the DKMS entry still points at it and
# needs it to rebuild after a kernel update or to retry the removal.
echo "Removing DKMS source tree..."
for tree in "/usr/src/${DRIVER_NAME}"*; do
    [ -e "$tree" ] || continue
    kept=""
    for version in "${failed_versions[@]}"; do
        if [ "$tree" = "/usr/src/${DRIVER_NAME}-${version}" ]; then
            kept="$version"
            break
        fi
    done
    if [ -n "$kept" ]; then
        echo "  kept ${tree}: its DKMS entry is still registered" >&2
        echo "  after unloading the module run: dkms remove -m ${DRIVER_NAME} -v ${kept} --all" >&2
        continue
    fi
    rm -rf "$tree"
done

echo "Removing module files and config..."
rm -f "/lib/modules/${KVER}/extra/${MODULE}.ko"
rm -f /etc/modprobe.d/minisforum-n5.conf /etc/modules-load.d/minisforum-n5.conf
depmod -a

echo ""
echo "uninstall complete for kernel ${KVER}: ${status_msg}"

echo ""
echo "Verify removal:"
if have dkms && dkms status 2>/dev/null | grep -q "^${DRIVER_NAME}[/,]"; then
    echo "  still registered in DKMS:"
    dkms status | grep "^${DRIVER_NAME}[/,]" | sed 's/^/    /'
else
    echo "  (not registered in DKMS - OK)"
fi
if lsmod | awk '{print $1}' | grep -qx "$MODULE"; then
    echo "  ${MODULE} is still loaded (it was in use)"
else
    echo "  (not loaded - OK)"
fi
