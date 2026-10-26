#!/usr/bin/env bash
# Minisforum N5 IT5571 — uninstaller
#
# Run as root: sudo ./scripts/uninstall.sh      (no arguments)
#
# Removes every install mode, including all registered DKMS versions, the
# modprobe/auto-load config, and the module of a --persistent install.
#
# A module that is in use cannot be unloaded. The script says so and removes
# the files anyway; unload it later with "modprobe -r minisforum_n5_it5571".

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

KVER="$(uname -r)"

[ $# -eq 0 ] || die "unexpected argument: $1 (this script takes no arguments)"

need_root

# A module in use stays loaded; warn and continue so the rest still runs.
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

failed_versions=()
if have dkms; then
    versions="$(dkms_registered_versions)"

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

# Keep the source tree of any version whose dkms remove failed: its
# registration still references that tree.
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
rm -f "$MODPROBE_CONF" "$MODULES_LOAD_CONF"
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

echo ""
echo "note: dkms and build tools installed by --dkms (or by you) are not touched."
if have dkms && [ -z "$(dkms status 2>/dev/null)" ]; then
    if have apt-get; then
        echo "dkms is not used by any module; remove it with: apt-get remove --purge dkms"
    elif have dnf; then
        echo "dkms is not used by any module; remove it with: dnf remove dkms"
    fi
fi
