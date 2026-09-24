#!/usr/bin/env bash
# Shared kernel/header dependency helpers for the Minisforum N5 driver
# installer. Source-only: defines functions, performs no actions.
#
# Supported: Debian / Ubuntu (regular kernel), Proxmox VE (pve kernel),
# Fedora / RHEL family. Anything else is rejected by os_family().
#
# detect_kernel_headers [exact]  -- pick the header packages to install.
#   Default: headers for the running kernel PLUS the distro's generic header
#   package (linux-headers-amd64/-generic, kernel-devel), which follows future
#   kernel updates -- needed so DKMS can rebuild after upgrades. "exact" keeps
#   only the running kernel's headers, enough for a one-off --test/--persistent
#   build. Exports KERNFAM, PKG_MGR, BUILD_PKGS and HEADER_PKGS.
#
# ensure_build_deps [exact]       -- installs only what is missing and records
#   the packages in INSTALLED_DEPS so cleanup_installed_deps() can remove them
#   again. All present -> no-op, nothing recorded.
#
# cleanup_installed_deps()        -- apt/dnf remove --purge + autoremove of
#   INSTALLED_DEPS, best-effort (warns, never aborts). No-op when empty.
#
# Test hooks (environment overrides, no system changes needed):
#   OS_RELEASE_FILE  path to an os-release file     (default: /etc/os-release)
#   UNAME_R          kernel release to pretend      (default: $(uname -r))
#   MODULES_DIR      module dir to check            (default: /lib/modules)

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
UNAME_R="${UNAME_R:-$(uname -r)}"
MODULES_DIR="${MODULES_DIR:-/lib/modules}"

# Packages this script installed during the current run (so the caller can
# remove them again afterwards with cleanup_installed_deps).
INSTALLED_DEPS=()

# install.sh defines its own die because it needs it before this file is
# sourced; the copies are identical and both are needed.
die()   { echo "error: $*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
warning() { echo "warning: $*" >&2; }

apt_resolvable()  { apt-cache show "$1" >/dev/null 2>&1; }
dnf_resolvable()  { dnf list --available "$1" >/dev/null 2>&1; }

os_family() {
  case "$UNAME_R" in
    *-pve)
      # /etc/os-release on Proxmox reports ID=debian, so the -pve kernel
      # suffix is the reliable signal.
      echo "proxmox"
      return 0
      ;;
  esac

  local id="" id_like=""
  if [ -f "$OS_RELEASE_FILE" ]; then
    id="$(sed -n 's/^ID=//p' "$OS_RELEASE_FILE" | tr -d '"')"
    id_like="$(sed -n 's/^ID_LIKE=//p' "$OS_RELEASE_FILE" | tr -d '"')"
  fi

  case "$id" in
    ubuntu) echo "ubuntu"; return 0 ;;
    debian) echo "debian"; return 0 ;;
    fedora) echo "fedora"; return 0 ;;
  esac

  case " $id_like " in
    *" debian "*)  echo "debian";  return 0 ;;
    *" fedora "*|*" rhel "*|*" centos "*) echo "fedora"; return 0 ;;
  esac

  die "unsupported distribution (${id:-unknown}; ID_LIKE=${id_like:-none}) -- supported: Debian, Ubuntu, Proxmox VE (pve kernel), Fedora/RHEL family"
}

detect_kernel_headers() {
  local want_exact=0
  [ "${1:-}" = exact ] && want_exact=1

  KERNFAM="$(os_family)"
  case "$KERNFAM" in
    proxmox)
      PKG_MGR="apt-get"
      BUILD_PKGS="build-essential"
      if [ "$want_exact" -eq 1 ]; then
        HEADER_PKGS="pve-headers-${UNAME_R}"
        apt_resolvable "pve-headers-${UNAME_R}" || {
          warning "pve-headers-${UNAME_R} not available; falling back to the generic pve-headers package"
          HEADER_PKGS="pve-headers"
        }
      else
        HEADER_PKGS="pve-headers"
        apt_resolvable pve-headers \
          || die "pve-headers is not available -- enable the Proxmox VE enterprise (or pve-no-subscription) repository, then rerun"
      fi
      ;;
    debian)
      PKG_MGR="apt-get"
      BUILD_PKGS="build-essential"
      HEADER_PKGS="linux-headers-${UNAME_R}"
      apt_resolvable "linux-headers-${UNAME_R}" \
        || die "custom or unsupported kernel: no package linux-headers-${UNAME_R} on this Debian -- install matching headers manually or use a distro kernel"
      if [ "$want_exact" -eq 0 ]; then
        HEADER_PKGS="${HEADER_PKGS} linux-headers-amd64"
        apt_resolvable linux-headers-amd64 \
          || warning "linux-headers-amd64 not available; manual rerun needed after future kernel upgrades"
      fi
      ;;
    ubuntu)
      PKG_MGR="apt-get"
      BUILD_PKGS="build-essential"
      HEADER_PKGS="linux-headers-${UNAME_R}"
      apt_resolvable "linux-headers-${UNAME_R}" \
        || die "custom or unsupported kernel: no package linux-headers-${UNAME_R} on this Ubuntu -- install matching headers manually or use a distro kernel"
      if [ "$want_exact" -eq 0 ]; then
        HEADER_PKGS="${HEADER_PKGS} linux-headers-generic"
        apt_resolvable linux-headers-generic \
          || warning "linux-headers-generic not available (HWE kernel?); manual rerun needed after future kernel upgrades"
      fi
      ;;
    fedora)
      PKG_MGR="dnf"
      BUILD_PKGS="gcc make"
      HEADER_PKGS="kernel-devel-${UNAME_R}"
      dnf_resolvable "kernel-devel-${UNAME_R}" \
        || die "custom or unsupported kernel: no package kernel-devel-${UNAME_R} -- install matching kernel-devel manually or use a distro kernel"
      if [ "$want_exact" -eq 0 ]; then
        if dnf_resolvable kernel-devel; then
          HEADER_PKGS="${HEADER_PKGS} kernel-devel"   # generic: follows future kernel updates
        else
          warning "generic kernel-devel package not available; rerun after kernel upgrades"
        fi
      fi
      ;;
  esac
}

ensure_build_deps() {
  if have gcc && have make && [ -d "${MODULES_DIR}/${UNAME_R}/build" ]; then
    return 0
  fi

  detect_kernel_headers "${1:-}"

  local missing=()
  if ! have gcc || ! have make; then
    missing+=($BUILD_PKGS)
  fi
  if [ ! -d "${MODULES_DIR}/${UNAME_R}/build" ]; then
    missing+=($HEADER_PKGS)
  fi

  echo "installing build dependencies via ${PKG_MGR}..." >&2
  case "$PKG_MGR" in
    apt-get)
      apt-get update -qq \
        && apt-get install -y "${missing[@]}" \
        || die "failed to install build dependencies (${missing[*]})"
      ;;
    dnf)
      dnf install -y "${missing[@]}" \
        || die "failed to install build dependencies (${missing[*]})"
      ;;
  esac

  INSTALLED_DEPS+=("${missing[@]}")

  [ -d "${MODULES_DIR}/${UNAME_R}/build" ] \
    || die "kernel headers for ${UNAME_R} were installed, but ${MODULES_DIR}/${UNAME_R}/build is missing"
}

# Removes whatever packages this run installed (see INSTALLED_DEPS), plus their
# transitive orphans. A no-op when nothing was installed. Never aborts; the
# cleanup is best-effort.
cleanup_installed_deps() {
  [ "${#INSTALLED_DEPS[@]}" -eq 0 ] && return 0

  case "${PKG_MGR:-}" in
    apt-get)
      echo "removing temporary build dependencies via apt-get..." >&2
      apt-get remove --purge -y "${INSTALLED_DEPS[@]}" \
        || warning "failed to remove temporary build dependencies (apt-get remove)"
      apt-get autoremove --purge -y \
        || warning "failed to autoremove orphaned packages"
      ;;
    dnf)
      echo "removing temporary build dependencies via dnf..." >&2
      dnf remove -y "${INSTALLED_DEPS[@]}" \
        || warning "failed to remove temporary build dependencies (dnf remove)"
      dnf autoremove -y \
        || warning "failed to autoremove orphaned packages"
      ;;
    *)
      warning "cannot remove build dependencies: unknown package manager (PKG_MGR=${PKG_MGR:-unset})"
      ;;
  esac
  INSTALLED_DEPS=()
}

ensure_dkms() {
  # No "exact" here: DKMS must be able to rebuild after a kernel upgrade, so it
  # needs the distro's generic header package too.
  ensure_build_deps
  have dkms && return 0

  detect_kernel_headers
  echo "installing dkms via ${PKG_MGR}..." >&2
  case "$PKG_MGR" in
    apt-get) apt-get install -y dkms || die "failed to install dkms" ;;
    dnf)     dnf install -y dkms     || die "failed to install dkms" ;;
  esac

  have dkms || die "dkms was installed but is not on PATH"
}