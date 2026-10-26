#!/usr/bin/env bash
# Shared helpers and constants for the Minisforum N5 driver scripts.
# Source-only: defines functions and variables, performs no actions.
#
# driver_version FILE  -- prints the version declared by the MODULE_VERSION
#   string in the driver source.
# dkms_registered_versions  -- prints each DKMS version registered for this
#   driver, one per line (nothing if dkms is missing or has no entry).

DRIVER_NAME="minisforum-n5-it5571"
MODULE="minisforum_n5_it5571"
MODPROBE_CONF="/etc/modprobe.d/minisforum-n5.conf"
MODULES_LOAD_CONF="/etc/modules-load.d/minisforum-n5.conf"

die()     { echo "error: $*" >&2; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }
warning() { echo "warning: $*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...)"; }

driver_version() {
  local v
  v="$(sed -n 's/.*MODULE_VERSION[[:space:]]*([[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1)"
  # sed exits 0 even when nothing matched, so an empty result means the source
  # is missing or the line was reformatted -- never treat that as a version.
  [ -n "$v" ] || die "cannot read MODULE_VERSION from ${1}"
  echo "$v"
}

dkms_registered_versions() {
  have dkms || return 0
  # Handles "name/ver, kver, arch: status" and the older "name, ver, kver, ...".
  { dkms status 2>/dev/null || true; } \
    | sed -n "s/^${DRIVER_NAME}[/,][[:space:]]*\([^,: [:space:]]*\).*/\1/p" \
    | sort -u
}
