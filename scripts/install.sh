#!/usr/bin/env bash
#
# Minisforum N5 (IT5571) fan driver -- installer for Proxmox/Debian
#
# Two ways to run it:
#
#   From the network (downloads the release tarball, verifies its checksum,
#   and installs directly from the extracted sources):
#
#     bash -c "$(curl -fsSL https://github.com/alexushkagz/minisforum-n5-it5571/releases/latest/download/install.sh)" install.sh --help
#     curl -fsSL https://github.com/alexushkagz/minisforum-n5-it5571/releases/latest/download/install.sh | bash -s -- --dkms
#
#   From a checkout of this repository (nothing is downloaded):
#
#     sudo ./scripts/install.sh --persistent
#
# Modes:
#   (no flag)  --test         build + insmod into the running kernel (read-only,
#                             no PWM writes). Nothing is persisted. Reboot.
#   --persistent              install into /lib/modules/<kver>/extra + modprobe
#                             config. Survives reboots; should be rebuilt after
#                             kernel updates.
#   --dkms                    full DKMS install, auto-rebuilt on kernel updates.
#   --uninstall               detect what is installed (insmod/modprobe/DKMS)
#                             and undo it, including config and /usr/src.
#   --help                    this help.
#
# Flags:
#   --enable-write            load with experimental_write=1 (PWM control
#                             enabled). Default: read-only sensors, no PWM
#                             writes. Works with any of the mode flags above.
#
set -euo pipefail

# ============================================================================
#  CONFIG -- version and checksum of the release this installer installs.
#  Cutting a new release means editing VERSION here, MODULE_VERSION in
#  driver-prototype/minisforum_n5_it5571.c, and the default versions in
#  release.sh and setup-dkms.sh.
# ============================================================================

VERSION="0.3.0"                                        # matches git tag v0.3.0
SHA256="<REPLACE: 64 hex chars from: sha256sum minisforum-n5-it5571-0.3.0.tar.gz>"

GH_USER="alexushkagz"
GH_REPO="minisforum-n5-it5571"

MODULE="minisforum_n5_it5571"

# Derived URLs -- nothing below this line needs editing per release.
BASE_URL="https://github.com/${GH_USER}/${GH_REPO}/releases/download/v${VERSION}"
TARBALL="minisforum-n5-it5571-${VERSION}.tar.gz"
TARBALL_URL="${BASE_URL}/${TARBALL}"

KVER="$(uname -r)"
ARCH="$(uname -m)"

ENABLE_WRITE=0
SRCDIR=""
TMP_DIR=""

# ============================================================================
#  Small helpers
# ============================================================================

die()   { echo "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...)"; }

usage() {
  cat <<'EOF'
Minisforum N5 (IT5571) driver installer for Proxmox/Debian

Usage:
  install.sh [--test | --persistent | --dkms | --uninstall | --help] [--enable-write]

  (default) --test
        Build the module and insmod it into the RUNNING kernel.
        Read-only sensors: no PWM writes. Nothing is persisted;
        a reboot returns you to BIOS control. First thing to try.

  --persistent
        Build and install into /lib/modules/<kernel>/extra, then register
        it with modprobe so it loads on every boot. Survives reboots, but
        the module is kernel-specific and must be re-run after kernel updates.

  --dkms
        Full DKMS install. The module is rebuilt automatically on every
        kernel update. Missing build dependencies and dkms itself are
        installed automatically for your distro.

  --uninstall
        Detects how the module is installed (insmod / persistent / DKMS)
        and undoes it: unloads, removes the .ko, depmod, deletes the
        modprobe/load config files and the /usr/src DKMS tree.

  --enable-write
        Load the module with experimental_write=1 (PWM control enabled).
        The default is READ-ONLY sensors, no PWM writes -- enable this
        only to experiment once the readings look right. Accepted in any
        position relative to the mode flag, e.g.:
          install.sh --dkms --enable-write
          install.sh --enable-write
          install.sh --test --enable-write

Notes:
  - Must run as root (via sudo).
  - The compiled .ko only works on the exact kernel it was built for.
  - Build dependencies (compiler + kernel headers) are resolved and
    installed automatically on Debian/Ubuntu, Proxmox VE, Fedora/RHEL.
    --test and --persistent remove what they installed when the script
    finishes (success or failure); --dkms keeps it.
  - CONFIG (VERSION, SHA256) lives at the top of this script.
EOF
}

check_build_deps() {
  # --test/--persistent only need headers for the running kernel, so "exact"
  # skips the distro's generic header packages (those matter only for future
  # DKMS rebuilds). Anything installed here is removed again on exit.
  ensure_build_deps exact
}

# ============================================================================
#  Source acquisition: prefer the local repo checkout; otherwise download the
#  release tarball from GitHub and install from the extracted files.
# ============================================================================

resolve_local_source() {
  # When install.sh is run from a git checkout it lives in scripts/, with the
  # driver sources one directory up. Echo the repo root if that layout exists.
  local here repo_root
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${here}/.." && pwd)"
  if [ -f "$repo_root/driver-prototype/minisforum_n5_it5571.c" ]; then
    echo "$repo_root"
    return 0
  fi
  return 1
}

fetch_release_tarball() {
  # Downloads and extracts the release tarball, then points SRCDIR at the
  # extracted sources. Removing TMP_DIR is main()'s on_exit handler's job.
  TMP_DIR="$(mktemp -d)"

  echo "downloading ${TARBALL_URL}" >&2
  curl -fsSL "$TARBALL_URL" -o "${TMP_DIR}/${TARBALL}" \
    || die "download failed -- is network up and tag v${VERSION} published?"

  if [[ "$SHA256" != \<* ]]; then
    if ! printf '%s  %s\n' "$SHA256" "${TMP_DIR}/${TARBALL}" | sha256sum --check - >/dev/null 2>&1; then
      actual="$(sha256sum "${TMP_DIR}/${TARBALL}" | cut -d' ' -f1)"
      die "checksum mismatch -- expected ${SHA256}, got ${actual}; re-run, or update SHA256 in CONFIG if this is a new release"
    fi
  else
    echo "warning: SHA256 not configured at the top of the script; skipping integrity check" >&2
  fi

  tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"

  # The folder the tarball extracts to depends on how the tarball was built,
  # so its name cannot be assumed. Find the extracted top-level folder and
  # accept it only if it holds the sources and shared lib we build from.
  local cand
  for cand in "$TMP_DIR"/*/; do
    [ -d "$cand" ] || continue
    [ -f "${cand}driver-prototype/${MODULE}.c" ] && [ -f "${cand}scripts/lib/kernel-deps.sh" ] || continue
    SRCDIR="${cand%/}"
    return 0
  done
  die "${TARBALL} does not look like a release tarball: expected one top-level folder containing driver-prototype/ and scripts/lib/"
}

prepare_source() {
  local src
  if src="$(resolve_local_source)"; then
    SRCDIR="$src"
    return 0
  fi
  # No checkout found (install.sh was probably piped via curl): download the
  # release tarball and install from it.
  [ "$ARCH" = "x86_64" ] || die "unsupported architecture: ${ARCH} (x86_64 required)"
  fetch_release_tarball
}

# ============================================================================
#  Build helpers
# ============================================================================

setup_build_tree() {
  # Build in a private copy so compiled files never land in the checkout.
  mkdir -p "$TMP_DIR"
  cp -r "$1/driver-prototype" "$TMP_DIR/driver-prototype"
  make -C "/lib/modules/${KVER}/build" M="$TMP_DIR/driver-prototype" clean >/dev/null 2>&1 || true
}

build_module() {
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
  if [ "$ENABLE_WRITE" -eq 1 ]; then
    insmod "$ko" experimental_write=1 \
      || die "insmod failed -- check dmesg (unsupported DMI? wrong kernel?)"
    echo "module loaded for testing (experimental_write=1, PWM control enabled)."
  else
    insmod "$ko" || die "insmod failed -- check dmesg (unsupported DMI? wrong kernel?)"
    echo "module loaded for testing (read-only sensors, no PWM writes)."
  fi

  echo "  sensors                    -> check temperatures/RPM"
  echo "  rmmod ${MODULE}            -> unload, return to BIOS control"
  echo "  rerun with --persistent or --dkms once the readings look right"
}

cmd_persistent() {
  check_build_deps
  local ko
  ko="$(build_module)"

  install -d "/lib/modules/${KVER}/extra"
  install -m 0644 "$ko" "/lib/modules/${KVER}/extra/${MODULE}.ko"
  depmod -a

  # A leftover DKMS/distro copy of the module would be picked by modprobe
  # from a higher-priority directory and shadow the file we just installed.
  # Check that modprobe resolves to our .ko before loading anything.
  local wanted actual
  wanted="/lib/modules/${KVER}/extra/${MODULE}.ko"
  actual="$(modinfo -n "$MODULE" 2>/dev/null || echo "$wanted")"
  [ "$actual" = "$wanted" ] || die "modprobe ${MODULE} resolves to ${actual}, not the freshly built ${wanted} -- a DKMS/distro install shadows it (run: install.sh --uninstall, or use --dkms)"

  if [ "$ENABLE_WRITE" -eq 1 ]; then
    echo "options ${MODULE} experimental_write=1" > /etc/modprobe.d/minisforum-n5.conf
  else
    rm -f /etc/modprobe.d/minisforum-n5.conf
  fi
  echo "$MODULE" > /etc/modules-load.d/minisforum-n5.conf

  modprobe "$MODULE" || die "load failed -- verify with: dmesg | grep ${MODULE}"

  echo "installed persistently for kernel ${KVER}."
  echo "the module is kernel-specific; rerun this script after every kernel update."
}

cmd_dkms() {
  # setup-dkms.sh installs any missing dependencies itself; this mode only
  # forwards the write flag and the release version.
  local args=()
  [ "$ENABLE_WRITE" -eq 1 ] && args+=(--enable-write)
  bash "$1/scripts/setup-dkms.sh" "${args[@]}" "$VERSION"
}

cmd_uninstall() {
  # uninstall.sh undoes every install mode (--test, --persistent, --dkms). It
  # is part of the repo and of the release tarball, so it is available in both
  # the checkout and the downloaded install path.
  bash "$SRCDIR/scripts/uninstall.sh"
}

# ============================================================================
#  Entry
# ============================================================================

main() {
  # Global, not local: the EXIT trap runs after main() returns, and it needs
  # to know which mode was used.
  action="test"
  ENABLE_WRITE=0
  for arg in "$@"; do
    case "$arg" in
      --test|test)          action="test" ;;
      --persistent|persistent) action="persistent" ;;
      --dkms|dkms)          action="dkms" ;;
      --uninstall)          action="uninstall" ;;
      --help|-h)            usage; exit 0 ;;
      --enable-write)       ENABLE_WRITE=1 ;;
      *)                    die "unknown option: $arg (see --help)" ;;
    esac
  done

  need_root

  # Single point of cleanup, registered before anything can create temporary
  # files, so every exit path below is covered: mode success, build failure,
  # --uninstall, and a download that dies halfway. Bash keeps only the last
  # trap set for a signal, so two separate EXIT traps would silently drop
  # whichever was registered first. The handler reads $action and $TMP_DIR when
  # it runs, so it does not matter that they are filled in later.
  on_exit() {
    # Defined only once the helper lib is sourced; the earlier exits have
    # nothing to clean up anyway.
    if declare -F cleanup_installed_deps >/dev/null 2>&1; then
      case "$action" in
        test|persistent) cleanup_installed_deps ;;
      esac
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
      echo "removing temporary directory ${TMP_DIR}" >&2
      rm -rf "$TMP_DIR"
    fi
    return 0
  }
  trap on_exit EXIT

  # Downloaded before the uninstall branch below: the removal itself lives in
  # scripts/uninstall.sh, which the one-liner does not have on disk yet.
  prepare_source "$@"

  if [ "$action" = "uninstall" ]; then
    cmd_uninstall
    exit 0
  fi

  # Helper lib with all the distro/kernel dependency logic. It is also shipped
  # inside the release tarball, so it exists in both the checkout and the
  # downloaded install path.
  . "$SRCDIR/scripts/lib/kernel-deps.sh"

  # The build runs in a private temp dir. In the downloaded-tarball path this
  # already exists and is reused; from a checkout it is created here. Either
  # way on_exit removes it.
  [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d)"
  setup_build_tree "$SRCDIR"

  case "$action" in
    test)        cmd_test ;;
    persistent)  cmd_persistent ;;
    dkms)        cmd_dkms "$SRCDIR" ;;
  esac
}

main "$@"