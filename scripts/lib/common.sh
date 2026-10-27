#!/usr/bin/env bash
# Shared helpers and constants for the Minisforum N5 driver scripts.
# Source-only: defines functions and variables, performs no actions.

DRIVER_NAME="minisforum-n5-it5571"
MODULE="minisforum_n5_it5571"
MODPROBE_CONF="/etc/modprobe.d/minisforum-n5.conf"
MODULES_LOAD_CONF="/etc/modules-load.d/minisforum-n5.conf"

die()     { echo "error: $*" >&2; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }
warning() { echo "warning: $*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...)"; }

# driver_version FILE  -- prints the version declared by the MODULE_VERSION
#   string in the driver source.
driver_version() {
  local v
  v="$(sed -n 's/.*MODULE_VERSION[[:space:]]*([[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1)"
  # sed exits 0 even when nothing matched, so an empty result means the source
  # is missing or the line was reformatted -- never treat that as a version.
  [ -n "$v" ] || die "cannot read MODULE_VERSION from ${1}"
  echo "$v"
}

# Prints each DKMS version registered for this
#   driver, one per line. Prints nothing and succeeds when dkms is missing or
#   has no entry; returns 1 when "dkms status" itself fails.
dkms_registered_versions() {
  have dkms || return 0
  local out
  out="$(dkms status 2>&1)" || return 1
  # Handles "name/ver, kver, arch: status" and the older "name, ver, kver, ...".
  printf '%s\n' "$out" \
    | sed -n "s/^${DRIVER_NAME}[/,][[:space:]]*\([^,: [:space:]]*\).*/\1/p" \
    | sort -u
}

# Query the driver module.
module_loaded() { lsmod | awk '{print $1}' | grep -qx "$MODULE"; }

# Unload the driver module.
unload_module() { modprobe -r "$MODULE" 2>/dev/null || rmmod "$MODULE" 2>/dev/null; }

# Unloads a loaded copy so a fresh build gets loaded; dies
#   if the module is in use.
reload_prepare() {
  module_loaded || return 0
  echo "unloading the currently loaded ${MODULE} so the new build takes effect" >&2
  unload_module \
    || die "${MODULE} is in use and cannot be unloaded; unload it manually (modprobe -r ${MODULE}) and rerun"
}
