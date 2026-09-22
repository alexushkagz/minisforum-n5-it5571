#!/usr/bin/env bash
#
# Minisforum N5 (IT5571) fan driver -- installer for Proxmox/Debian
#
# Two ways to run it:
#
#   From the network (downloads the pinned release tarball, verifies it,
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
#                             config. Survives reboots; rebuild after kernel updates.
#   --dkms                    full DKMS install, auto-rebuilt on kernel updates.
#   --uninstall               detect what is installed (insmod/modprobe/DKMS)
#                             and undo it, including config and /usr/src.
#   --help                    this help.
#
# Flags:
#   --enable-write            load with experimental_write=1 (PWM control
#                             enabled). Default is READ-ONLY: laboratory/test
#                             value, sensors only, no PWM writes. Accepted in
#                             any position relative to the mode flag.
#
set -euo pipefail

# ============================================================================
#  CONFIG -- the only block to edit when a new release is cut.
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
have()  { command -v "$1" >/dev/null 2>&1; }
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
        kernel update. Checks that `dkms`, `build-essential` and
        `linux-headers-$(uname -r)` are present and prints the apt command
        for anything missing.

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
  - CONFIG (VERSION, SHA256) lives at the top of this script.
EOF
}

check_build_deps() {
  local missing=""
  have gcc  || missing="${missing} gcc"
  have make || missing="${missing} make"
  [ -d "/lib/modules/${KVER}/build" ] || [ -d "/usr/src/linux-headers-${KVER}" ] \
    || missing="${missing} linux-headers-${KVER}"
  [ -z "$missing" ] || {
    echo "error: missing packages required to build the module:$missing" >&2
    echo "install them with:" >&2
    echo "  sudo apt-get update" >&2
    echo "  sudo apt-get install -y build-essential linux-headers-${KVER}" >&2
    exit 1
  }
}

check_dkms_deps() {
  check_build_deps
  have dkms || {
    echo "error: missing package: dkms" >&2
    echo "install it with:" >&2
    echo "  sudo apt-get update && sudo apt-get install -y dkms" >&2
    exit 1
  }
}

# ============================================================================
#  Source acquisition: use the repo checkout if present, otherwise fetch the
#  pinned release tarball into a temp dir and build from the extracted tree.
# ============================================================================

resolve_local_source() {
  # This script normally lives in scripts/; the driver sources are one level
  # up. Return the REPO ROOT, which every other function expects.
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
  # Sets the TMP_DIR (cleaned by the EXIT trap) and SRCDIR globals.
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  echo "downloading ${TARBALL_URL}" >&2
  curl -fsSL "$TARBALL_URL" -o "${TMP_DIR}/${TARBALL}" \
    || die "download failed -- is network up and tag v${VERSION} published?"

  if [[ "$SHA256" != \<* ]]; then
    echo "${SHA256}  ${TMP_DIR}/${TARBALL}" | sha256sum --check - >/dev/null 2>&1 \
      || die "checksum mismatch -- tarball tampered or SHA256 not updated in CONFIG"
  else
    echo "warning: SHA256 not configured at the top of the script; skipping integrity check" >&2
  fi

  tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
  SRCDIR="${TMP_DIR}/minisforum-n5-it5571-${VERSION}"
}

prepare_source() {
  local src
  if src="$(resolve_local_source)"; then
    SRCDIR="$src"
    return 0
  fi
  # Running from a pipe or temp copy: fall back to the pinned release tarball
  # and build directly from its extracted tree (nothing is downloaded when a
  # checkout is available).
  [ "$ARCH" = "x86_64" ] || die "unsupported architecture: ${ARCH} (x86_64 required)"
  fetch_release_tarball
}

# ============================================================================
#  Build helpers
# ============================================================================

setup_build_tree() {
  # Keep build artifacts out of the repo checkout: build on a fresh copy.
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

  install -m 0644 "$ko" "/lib/modules/${KVER}/extra/${MODULE}.ko"
  depmod -a

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
  check_dkms_deps
  local args=()
  [ "$ENABLE_WRITE" -eq 1 ] && args+=(--enable-write)
  bash "$1/scripts/setup-dkms.sh" "${args[@]}" "$VERSION"
}

cmd_uninstall() {
  need_root
  local status_msg="${KVER}: nothing found to remove"

  if lsmod | awk '{print $1}' | grep -qx "$MODULE"; then
    modprobe -r "$MODULE" || rmmod "$MODULE"
    status_msg="unloaded running module"
  fi

  rm -f "/lib/modules/${KVER}/extra/${MODULE}.ko"
  rm -f /etc/modprobe.d/minisforum-n5.conf /etc/modules-load.d/minisforum-n5.conf
  depmod -a

  if have dkms && dkms status 2>/dev/null | grep -q "^minisforum-n5-it5571,"; then
    local ver
    ver="$(dkms status | sed -n 's/^minisforum-n5-it5571, \([0-9.]*\).*/\1/p' | head -1)"
    dkms remove -m minisforum-n5-it5571 -v "$ver" --all 2>/dev/null || true
    rm -rf /usr/src/minisforum-n5-it5571-*
    status_msg="${status_msg}; removed DKMS registration"
  fi

  echo "uninstall complete: ${status_msg}"
}

# ============================================================================
#  Entry
# ============================================================================

main() {
  local action="test"
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

  if [ "$action" = "uninstall" ]; then
    cmd_uninstall
    exit 0
  fi

  need_root

  prepare_source "$@"

  # Everything below builds a kernel module, so give the build its own temp dir
  # (reusing the tarball's temp dir in network mode) and guarantee cleanup even
  # on failure.
  if [ -z "$TMP_DIR" ]; then
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
  fi
  setup_build_tree "$SRCDIR"

  case "$action" in
    test)        cmd_test ;;
    persistent)  cmd_persistent ;;
    dkms)        cmd_dkms "$SRCDIR" ;;
  esac
}

main "$@"