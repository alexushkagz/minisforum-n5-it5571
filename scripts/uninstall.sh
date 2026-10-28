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
#
# If "dkms status" fails, the DKMS state is unknown: all /usr/src trees are
# kept and the manual cleanup commands are printed. Copies of the module left
# in other kernels' module directories are listed, never deleted.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

KVER="$(uname -r)"

[ $# -eq 0 ] || die "unexpected argument: $1 (this script takes no arguments)"

need_root

# A module in use stays loaded; warn and continue so the rest still runs.
banner "Unloading and DKMS"
status_msg="module was not loaded"
if module_loaded; then
    if unload_module; then
        status_msg="unloaded the running module"
    else
        warning "module is in use and stays loaded; removing files/registration anyway"
        echo "  unload later with: modprobe -r ${MODULE}" >&2
        status_msg="module still loaded (in use)"
    fi
fi

failed_versions=()
dkms_unreadable=0
if have dkms; then
    if ! versions="$(dkms_registered_versions)"; then
        dkms_unreadable=1
        versions=""
        warning "could not read DKMS state (dkms status failed)"
        status_msg="${status_msg}; DKMS state unreadable, source trees kept"
    fi

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
banner "DKMS source trees"
for tree in "/usr/src/${DRIVER_NAME}"*; do
    [ -e "$tree" ] || continue
    if [ "$dkms_unreadable" -eq 1 ]; then
        echo "  kept ${tree}: DKMS state could not be read" >&2
        echo "  once dkms works run: dkms remove -m ${DRIVER_NAME} -v VERSION --all && rm -rf ${tree}" >&2
        continue
    fi
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

banner "Module files and config"
rm -f "/lib/modules/${KVER}/extra/${MODULE}.ko"
rm -f "$MODPROBE_CONF" "$MODULES_LOAD_CONF"
depmod -a

others=()
for ko in /lib/modules/*/extra/${MODULE}.ko; do
    [ -e "$ko" ] || continue
    [ "$ko" = "/lib/modules/${KVER}/extra/${MODULE}.ko" ] && continue
    others+=("$ko")
done
if [ "${#others[@]}" -gt 0 ]; then
    echo "copies left for other kernels:"
    printf '  %s\n' "${others[@]}"
    echo "remove them with: rm -f ${others[*]}"
    echo "then run: depmod -a"
fi

summary_add OK "uninstalled for kernel ${KVER}: ${status_msg}"
if have dkms && dkms status 2>/dev/null | grep -q "^${DRIVER_NAME}[/,]"; then
    summary_add WARN "still registered in DKMS (see: dkms status)"
else
    summary_add OK "not registered in DKMS"
fi
if module_loaded; then
    summary_add WARN "${MODULE} is still loaded (it was in use)"
else
    summary_add OK "not loaded"
fi

summary_add NEXT "dkms and build tools installed by --dkms (or by you) were not touched"
if have dkms && [ -z "$(dkms status 2>/dev/null)" ]; then
    if have apt-get; then
        summary_add NEXT "dkms is not used by any module; remove it with: apt-get remove --purge dkms"
    elif have dnf; then
        summary_add NEXT "dkms is not used by any module; remove it with: dnf remove dkms"
    fi
fi
summary_print

