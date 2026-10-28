#!/usr/bin/env bash
#
# Minisforum N5 (IT5571) fan driver -- installer (Debian/Ubuntu, Proxmox VE, Fedora/RHEL)
#
# Builds and installs the driver from the sources sitting next to this script.
# Run it with --help for the available modes and flags.
#
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ============================================================================
#  CONFIG
# ============================================================================

KVER="$(uname -r)"
ARCH="$(uname -m)"

ENABLE_WRITE=0
SRCDIR=""
TMP_DIR=""

# ============================================================================
#  Small helpers
# ============================================================================

usage() {
  cat <<'EOF'
Minisforum N5 (IT5571) driver installer (Debian/Ubuntu, Proxmox VE, Fedora/RHEL)

Usage:
  install.sh [--test | --persistent | --dkms | --uninstall | --help | -h] [--enable-write]

Modes:
  (default) --test
        Build the module and insmod it into the RUNNING kernel.
        Read-only sensors: no PWM writes. Nothing is persisted;
        a reboot returns you to BIOS control. First thing to try.
        An already-loaded copy is unloaded first.

  --persistent
        Build and install into /lib/modules/<kernel>/extra, then register
        it with modprobe so it loads on every boot. Survives reboots, but
        the module is kernel-specific and must be re-run after kernel updates.
        An already-loaded copy is unloaded first.

  --dkms
        Full DKMS install. The module is rebuilt automatically on every
        kernel update. Missing build dependencies, the header metapackage
        and dkms itself are installed automatically and kept.
        An already-loaded copy is unloaded first.

  --uninstall
        Detects how the module is installed (insmod / persistent / DKMS)
        and undoes it: unloads, removes the .ko, depmod, deletes the
        modprobe/load config files and the /usr/src DKMS tree (kept if
        the DKMS state cannot be read).
        Only the running kernel's .ko is removed; copies left for other
        kernels are listed.

  --help, -h
        Show this help.

Flags:
  --enable-write
        Load the module with enable_write=1 (PWM control enabled).
        The default is READ-ONLY sensors, no PWM writes -- enable this
        only to experiment once the readings look right. Applies to
        --test, --persistent and --dkms (ignored by --uninstall).
        Accepted in any position relative to the mode flag, e.g.:
          install.sh --dkms --enable-write
          install.sh --enable-write
          install.sh --test --enable-write

Notes:
  - Must run as root (via sudo).
  - The compiled .ko only works on the exact kernel it was built for.
  - Build dependencies (compiler + kernel headers) are resolved and
    installed automatically on Debian/Ubuntu, Proxmox VE, Fedora/RHEL.
    --test and --persistent install only what is missing and remove exactly
    those packages when the script finishes (success or failure); no
    autoremove is run. --dkms keeps what it installed.
EOF
}

check_build_deps() {
  # Anything installed here is removed again on exit.
  ensure_build_deps exact
}

# ============================================================================
#  Source acquisition: locate the sources that belong to this script. A clone
#  and an unpacked release have the same layout, so one lookup covers both.
# ============================================================================

resolve_local_source() {
  local here repo_root
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${here}/.." && pwd)"
  if [ -f "$repo_root/driver-prototype/minisforum_n5_it5571.c" ]; then
    echo "$repo_root"
    return 0
  fi
  return 1
}

prepare_source() {
  [ "$ARCH" = "x86_64" ] || die "unsupported architecture: ${ARCH} (x86_64 required)"
  SRCDIR="$(resolve_local_source)" \
    || die "driver sources not found next to this script -- expected driver-prototype/ one directory above scripts/."
}

# ============================================================================
#  Build helpers
# ============================================================================

setup_build_tree() {
  # Build in a private copy so compiled files never land in the checkout.
  mkdir -p "$TMP_DIR/driver-prototype"
  cp "$1/driver-prototype/${MODULE}.c" "$1/driver-prototype/Makefile" "$TMP_DIR/driver-prototype/"
}

build_module() {
  banner "Building the module"
  make -C "/lib/modules/${KVER}/build" M="$TMP_DIR/driver-prototype" modules >/dev/null \
    || die "kernel module build failed (see error above)"
  [ -f "$TMP_DIR/driver-prototype/${MODULE}.ko" ] || die "build produced no .ko file"
  echo "$TMP_DIR/driver-prototype/${MODULE}.ko"
}

# ============================================================================
#  Modes
# ============================================================================

cmd_test() {
  check_build_deps
  local ko
  ko="$(build_module)"
  banner "Loading the module"
  reload_prepare
  if [ "$ENABLE_WRITE" -eq 1 ]; then
    insmod "$ko" enable_write=1 \
      || die "insmod failed -- check dmesg (unsupported DMI? wrong kernel?)"
    summary_add OK "loaded for testing with PWM writes ENABLED (enable_write=1)"
  else
    insmod "$ko" || die "insmod failed -- check dmesg (unsupported DMI? wrong kernel?)"
    summary_add OK "loaded for testing (read-only sensors, no PWM writes)"
  fi

  summary_add NEXT "check temperatures and RPM: sensors"
  summary_add NEXT "unload and return to BIOS control: rmmod ${MODULE}"
  summary_add NEXT "keep it: rerun with --persistent or --dkms once the readings look right"
}

# Removes the installed .ko again; config files are left to the caller.
rollback_persistent() {
  rm -f "/lib/modules/${KVER}/extra/${MODULE}.ko"
  depmod -a
}

cmd_persistent() {
  check_build_deps
  local ko
  ko="$(build_module)"

  local installed="/lib/modules/${KVER}/extra/${MODULE}.ko"
  banner "Installing for kernel ${KVER}"
  install -d "/lib/modules/${KVER}/extra"
  install -m 0644 "$ko" "$installed"
  depmod -a

  # A leftover DKMS/distro copy of the module would be picked by modprobe
  # from a higher-priority directory and shadow the file we just installed.
  # Check that modprobe resolves to our .ko before loading anything.
  local actual
  actual="$(modinfo -n "$MODULE" 2>/dev/null)" || actual=""
  if [ -z "$actual" ]; then
    rollback_persistent
    die "modinfo cannot find ${MODULE} after install -- check depmod/modules dir"
  fi
  if [ "$actual" != "$installed" ]; then
    rollback_persistent
    die "modprobe ${MODULE} resolves to ${actual}, not the freshly built ${installed} -- a DKMS/distro install shadows it (run: install.sh --uninstall, or use --dkms)"
  fi

  if [ "$ENABLE_WRITE" -eq 1 ]; then
    echo "options ${MODULE} enable_write=1" > "$MODPROBE_CONF"
  else
    rm -f "$MODPROBE_CONF"
  fi

  banner "Loading the module"
  reload_prepare
  if ! modprobe "$MODULE"; then
    rollback_persistent
    rm -f "$MODPROBE_CONF"
    die "load failed -- verify with: dmesg | grep ${MODULE}"
  fi
  echo "$MODULE" > "$MODULES_LOAD_CONF"

  if [ "$ENABLE_WRITE" -eq 1 ]; then
    summary_add OK "installed for kernel ${KVER}, loads on boot, PWM writes ENABLED"
  else
    summary_add OK "installed for kernel ${KVER}, loads on boot (read-only sensors)"
  fi
  summary_add NEXT "the module is kernel-specific: rerun this script after every kernel update, or use --dkms"
}

cmd_dkms() {
  local args=()
  [ "$ENABLE_WRITE" -eq 1 ] && args+=(--enable-write)
  bash "$1/scripts/setup-dkms.sh" "${args[@]}"
}

cmd_uninstall() {
  bash "$SRCDIR/scripts/uninstall.sh"
}

# ============================================================================
#  Entry
# ============================================================================

main() {
  # Global, not local: the EXIT trap reads it after main() returns.
  action="test"
  ENABLE_WRITE=0
  for arg in "$@"; do
    case "$arg" in
      --test)               action="test" ;;
      --persistent)         action="persistent" ;;
      --dkms)               action="dkms" ;;
      --uninstall)          action="uninstall" ;;
      --help|-h)            usage; exit 0 ;;
      --enable-write)       ENABLE_WRITE=1 ;;
      *)                    die "unknown option: $arg (see --help)" ;;
    esac
  done

  need_root

  # Registered before anything can create temporary state, so every exit path
  # is covered. Bash keeps only the last trap set for a signal, so two
  # separate EXIT traps would silently drop whichever came first.
  on_exit() {
    if declare -F cleanup_installed_deps >/dev/null 2>&1; then
      case "$action" in
        test|persistent) cleanup_installed_deps ;;
      esac
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
      echo "removing temporary directory ${TMP_DIR}" >&2
      rm -rf "$TMP_DIR"
    fi
    summary_print
    return 0
  }
  trap on_exit EXIT

  prepare_source "$@"

  if [ "$action" = "uninstall" ]; then
    cmd_uninstall
    exit 0
  fi

  . "$SRCDIR/scripts/lib/kernel-deps.sh"

  case "$action" in
    test|persistent)
      TMP_DIR="$(mktemp -d)"
      setup_build_tree "$SRCDIR"
      "cmd_${action}"
      ;;
    dkms)  cmd_dkms "$SRCDIR" ;;
  esac
}

main "$@"