#!/usr/bin/env bash
# Shared kernel/header dependency helpers for the Minisforum N5 driver
# installer. Source-only: defines functions, performs no actions.
#
# Supported: Debian / Ubuntu (regular kernel), Proxmox VE (pve kernel),
# Fedora / RHEL 8+ (dnf). Anything else is rejected by os_family().
#
# Functions you can call:
#
#   ensure_build_deps exact|dkms
#       Installs whatever build dependencies are missing, in one package-manager
#       transaction. Packages that are already installed are left alone.
#         exact -- compiler + headers for the running kernel
#                  (used by --test and --persistent).
#         dkms  -- the above, plus the distro's header metapackage (so DKMS can
#                  rebuild after kernel updates) and the dkms package itself.
#   ensure_dkms
#       Shorthand for "ensure_build_deps dkms".
#   cleanup_installed_deps
#       Removes the packages this script installed -- and only those. Packages
#       that were already on the system are never touched, and no "autoremove"
#       is run. If removal fails it prints a warning and carries on.
#
# What was installed is remembered in two variables, used by the cleanup:
#   INSTALLED_DEPS  list of packages installed by ensure_build_deps
#   DNF_UNDO        set to 1 after a successful dnf install (Fedora/RHEL); the
#                   cleanup then undoes that dnf transaction instead of
#                   removing packages one by one
#
# Test hooks (environment overrides, no system changes needed):
#   OS_RELEASE_FILE  path to an os-release file     (default: /etc/os-release)
#   UNAME_R          kernel release to pretend      (default: $(uname -r))
#   MODULES_DIR      module dir to check            (default: /lib/modules)

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
UNAME_R="${UNAME_R:-$(uname -r)}"
MODULES_DIR="${MODULES_DIR:-/lib/modules}"

INSTALLED_DEPS=()
DNF_UNDO=0

pkg_installed() {
  case "$PKG_MGR" in
    apt-get) [ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" = "ii " ] ;;
    dnf)     rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

# True only for packages with a real candidate; virtual names do not count.
pkg_available() {
  case "$PKG_MGR" in
    apt-get)
      apt-cache policy "$1" 2>/dev/null \
        | awk '/^ *Candidate:/ { found = 1; ok = ($2 != "(none)") } END { exit !(found && ok) }'
      ;;
    dnf) dnf list --available "$1" >/dev/null 2>&1 ;;
  esac
}

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

set_distro() {
  KERNFAM="$(os_family)"
  case "$KERNFAM" in
    fedora) PKG_MGR="dnf";     BUILD_PKGS="gcc make" ;;
    *)      PKG_MGR="apt-get"; BUILD_PKGS="build-essential" ;;
  esac
}

headers_present() { [ -d "${MODULES_DIR}/${UNAME_R}/build" ]; }

# Echoes the package providing headers for the running kernel, or returns 1.
resolve_exact_headers() {
  local p
  case "$KERNFAM" in
    proxmox) set -- "proxmox-headers-${UNAME_R}" "pve-headers-${UNAME_R}" ;;
    debian)  set -- "linux-headers-${UNAME_R}" ;;
    ubuntu)  set -- "linux-headers-${UNAME_R}" ;;
    fedora)  set -- "kernel-devel-${UNAME_R}" ;;
  esac
  for p in "$@"; do
    if pkg_available "$p"; then echo "$p"; return 0; fi
  done
  return 1
}

# Echoes the header metapackage that keeps headers current across kernel
# updates. Prints nothing (after a warning) when none is known for this kernel.
resolve_header_meta() {
  local p cands=()
  case "$KERNFAM" in
    proxmox) cands=(proxmox-default-headers pve-headers) ;;
    fedora)  cands=(kernel-devel-matched kernel-devel) ;;
    debian)
      case "$UNAME_R" in
        *-amd64) cands=(linux-headers-amd64) ;;
      esac ;;
    ubuntu)
      case "$UNAME_R" in
        *-generic) cands=(linux-headers-generic) ;;
      esac ;;
  esac

  if [ "${#cands[@]}" -eq 0 ]; then
    warning "no header metapackage known for this kernel flavour (${UNAME_R}); install matching headers manually so DKMS can rebuild after kernel updates"
    return 0
  fi

  # Already installed under any candidate name: nothing to do.
  for p in "${cands[@]}"; do
    if pkg_installed "$p"; then echo "$p"; return 0; fi
  done
  for p in "${cands[@]}"; do
    if pkg_available "$p"; then echo "$p"; return 0; fi
  done

  case "$KERNFAM" in
    proxmox) die "no Proxmox header package available (tried: ${cands[*]}) -- enable the Proxmox repository (pve-no-subscription or enterprise) and rerun" ;;
    fedora)  warning "neither kernel-devel-matched nor kernel-devel is available; install kernel headers manually so DKMS can rebuild after kernel updates" ;;
    *)       warning "${cands[0]} is not available; install matching headers manually so DKMS can rebuild after kernel updates" ;;
  esac
}

ensure_build_deps() {
  local mode="${1:-}" p
  case "$mode" in
    exact|dkms) ;;
    *) die "ensure_build_deps: mode must be 'exact' or 'dkms'" ;;
  esac

  set_distro

  local missing=()
  for p in $BUILD_PKGS; do
    pkg_installed "$p" || missing+=("$p")
  done

  local meta=""
  if ! headers_present; then
    if p="$(resolve_exact_headers)"; then
      missing+=("$p")
    else
      case "$KERNFAM" in
        proxmox)
          warning "no exact headers package for ${UNAME_R}; falling back to the Proxmox header metapackage"
          meta="$(resolve_header_meta)"
          [ -n "$meta" ] && missing+=("$meta")
          ;;
        fedora) die "custom or unsupported kernel: no package kernel-devel-${UNAME_R} -- install matching kernel-devel manually or use a distro kernel" ;;
        *)      die "custom or unsupported kernel: no package linux-headers-${UNAME_R} -- install matching headers manually or use a distro kernel" ;;
      esac
    fi
  fi

  if [ "$mode" = dkms ]; then
    if [ -z "$meta" ]; then
      meta="$(resolve_header_meta)"
    fi
    if [ -n "$meta" ] && ! pkg_installed "$meta"; then
      case " ${missing[*]} " in *" $meta "*) ;; *) missing+=("$meta") ;; esac
    fi
    pkg_installed dkms || missing+=(dkms)
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    install_packages "${missing[@]}"
  fi

  headers_present \
    || die "kernel headers for the running kernel (${UNAME_R}) are not available (${MODULES_DIR}/${UNAME_R}/build is missing). If a newer kernel was installed but not booted yet, reboot into the newest kernel, or install headers for the running kernel manually"

  if [ "$mode" = dkms ] && [ "${#INSTALLED_DEPS[@]}" -gt 0 ]; then
    echo "kept for future DKMS rebuilds: ${INSTALLED_DEPS[*]}" >&2
  fi
}

install_packages() {
  local missing=("$@")
  echo "installing build dependencies via ${PKG_MGR}: ${missing[*]}" >&2

  case "$PKG_MGR" in
    apt-get)
      apt-get update -qq || die "failed to update package lists. Check your repositories (e.g. a Proxmox enterprise repository without a subscription: disable it or use pve-no-subscription), then run manually: apt-get update && apt-get install ${missing[*]}"

      # Ask apt what would be newly installed (dependencies included) so only
      # that is removed later; lines "Inst pkg [old] (new)" are upgrades.
      local planned=() line
      while IFS= read -r line; do
        planned+=("$line")
      done < <(apt-get -s install "${missing[@]}" 2>/dev/null \
                 | awk '$1 == "Inst" && $3 !~ /^\[/ { print $2 }')
      if [ "${#planned[@]}" -eq 0 ]; then
        planned=("${missing[@]}")
      fi
      INSTALLED_DEPS=("${planned[@]}")

      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
        echo "to undo a partial install, run: apt-get remove --purge ${INSTALLED_DEPS[*]}" >&2
        INSTALLED_DEPS=()
        die "failed to install build dependencies (${missing[*]})"
      fi
      ;;
    dnf)
      INSTALLED_DEPS=("${missing[@]}")
      if ! dnf install -y "${missing[@]}"; then
        echo "to undo a partial install, run: dnf history undo last   (or: dnf remove ${INSTALLED_DEPS[*]})" >&2
        INSTALLED_DEPS=()
        die "failed to install build dependencies (${missing[*]})"
      fi
      DNF_UNDO=1
      ;;
  esac
}

cleanup_installed_deps() {
  [ "${#INSTALLED_DEPS[@]}" -eq 0 ] && return 0

  case "${PKG_MGR:-}" in
    apt-get)
      echo "removing installed build dependencies: ${INSTALLED_DEPS[*]}" >&2
      apt-get remove --purge -y "${INSTALLED_DEPS[@]}" \
        || warning "failed to remove build dependencies; remove manually: apt-get remove --purge ${INSTALLED_DEPS[*]}"
      ;;
    dnf)
      echo "removing installed build dependencies: ${INSTALLED_DEPS[*]}" >&2
      if [ "$DNF_UNDO" -eq 1 ] && dnf history undo last -y; then
        :
      else
        dnf remove -y "${INSTALLED_DEPS[@]}" \
          || warning "failed to remove build dependencies; remove manually: dnf remove ${INSTALLED_DEPS[*]}"
      fi
      ;;
    *)
      warning "cannot remove build dependencies: unknown package manager (PKG_MGR=${PKG_MGR:-unset})"
      ;;
  esac
  INSTALLED_DEPS=()
  DNF_UNDO=0
}

ensure_dkms() {
  ensure_build_deps dkms
}
