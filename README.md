# Minisforum N5 fan driver for Proxmox VE, Debian/Ubuntu and Fedora/RHEL

The Minisforum N5-family NAS has no fan control in the Linux kernel: all the
work is done by an embedded controller (ITE IT5571) that only the BIOS knows
how to talk to. This driver gives that controller a standard `hwmon`
interface, so on Proxmox you can finally read the temperatures and take manual
control of the fans instead of letting the firmware decide everything.

It is a fork of the community driver by
[ltdstudio](https://github.com/ltdstudio/minisforum-n5-it5571) — the guy
who reverse-engineered the EC and originally shipped this as an Unraid plugin.
This fork keeps that driver intact, but adapts it to install and run as a
plain kernel module on Debian/Ubuntu, Proxmox VE and the Fedora/RHEL family,
and adds official support for one hardware combination the upstream DMI check
did not yet know about.

## Why this fork exists

Two things pushed me to fork rather than just use the original repository.

First, the original is packaged for **Unraid**: the plugin file, the WebGUI
sources under `src/`, the `.txz` package builder and the Community
Applications docs. None of that applies to Proxmox; it only gets in the way.

Second, my own machine — an **N5 PRO with an F8NAB mainboard** — was refused
by the driver on load. Upstream accepts `N5/F8NAA`, `N5 PRO/F8NAA` and
`N5A/F8NAB`, but it simply had no entry for the `N5 PRO + F8NAB` combination,
so the probe aborted with an `-ENODEV: unsupported system`. That combination
now has its own board profile in
[`driver-prototype/minisforum_n5_it5571.c`](driver-prototype/minisforum_n5_it5571.c).

## Repository layout

Keeping the original structure made it easy to track upstream while giving the
Proxmox parts their own place:

- **`driver-prototype/`** — the driver itself: `minisforum_n5_it5571.c` and the
  kernel module `Makefile` (see its [README](driver-prototype/README.md) for
  manual build and load). The path mirrors the upstream repo exactly, so the
  driver can be merged forward cleanly as the original project evolves.
- **`scripts/`** — `install.sh` builds and installs the driver from the sources
  next to it, so it runs either from a clone or from inside an unpacked
  release. `get.sh` is the download entrypoint: it fetches a release, verifies
  its checksum and hands over to `install.sh`. `setup-dkms.sh` and
  `uninstall.sh` are the DKMS installer and the standalone uninstaller, both
  runnable directly. `lib/kernel-deps.sh` holds the shared distro/kernel-header
  logic, and `release.sh` builds the release artifacts (see
  [Releasing](#releasing)).
- **`unraid-legacy/`** — everything Unraid-only from the original repository,
  moved here unchanged for reference: the plugin file, the WebGUI sources, the
  `.txz` and kernel build scripts, the reverse-engineering tools, the
  screenshots, and all the original documentation. Nothing in this folder is
  needed to run the driver.
- **`LICENSE` / `LICENSES/`** — the GPL-2.0 material covering the driver
  source.

## What the driver does

Loaded, the module registers an `hwmon` device with four fan channels — CPU,
SSD, HDD group and the PCIe fan (that last one has no tachometer signal on the
board, so it honestly reports 0 RPM) — and four EC temperature sensors: CPU,
System, Board and Ambient.

Each PWM channel can be switched between the EC's automatic curve and manual
control, and the driver restores the automatic mode for the channels it
actually touched when it is unloaded. The module is read-only by default on
every supported board: PWM writes are only enabled after you deliberately load
it with `enable_write=1` (which is what the installer's `--enable-write` does)
once the sensor readings look right.

## Installing

The installer detects your distro and running kernel, installs any missing
build dependencies (compiler + matching kernel headers) automatically, and
supports Debian/Ubuntu with a stock kernel, Proxmox VE (`-pve` kernel), and the
Fedora/RHEL family (Fedora 8+).

**One-liner** — `get.sh` downloads the release archive, verifies its SHA-256,
and hands over to the installer:

```bash
sudo bash -c "$(curl -fsSL https://github.com/alexushkagz/minisforum-n5-it5571/releases/latest/download/get.sh)" -- --persistent

# Pipe variant of the same one-liner:
curl -fsSL https://github.com/alexushkagz/minisforum-n5-it5571/releases/latest/download/get.sh \
  | sudo bash -s -- --persistent
```

**From a clone** — build and install straight from the checkout:

```bash
git clone https://github.com/alexushkagz/minisforum-n5-it5571
cd minisforum-n5-it5571
sudo ./scripts/install.sh --persistent
```

On Proxmox VE you usually work as `root` already, so drop `sudo` from any of
these commands.

Modes:
- `--test` (default) — build and load into the running kernel; read-only
  sensors unless `--enable-write`. Nothing persisted; a reboot returns to BIOS
  control. Temporary build dependencies (toolchain + this kernel's headers)
  are auto-installed if missing and removed again when the script finishes.
- `--persistent` — install into `/lib/modules/<kernel>/extra` and load on boot
  via modprobe. Kernel-specific: **rerun it after every kernel update** (or
  prefer `--dkms` so this happens automatically). Temporary build dependencies
  are auto-installed if missing and removed again when the script finishes.
- `--dkms` — register with DKMS. The module is rebuilt automatically whenever
  a kernel update brings new headers. Build dependencies (incl. the header
  meta-package) and dkms are installed once and **kept**.
- `--uninstall` — detect what is installed and undo it.

`--enable-write` applies to `--test`, `--persistent` and `--dkms`.

The helper scripts can also be run directly. `setup-dkms.sh` performs a DKMS
install. `uninstall.sh` is the full uninstaller: it takes no arguments and
undoes `--dkms`, `--persistent` and `--test` installs alike, removing every
registered DKMS version. It is what `install.sh --uninstall` calls.

```bash
sudo ./scripts/setup-dkms.sh --enable-write
sudo ./scripts/uninstall.sh
```

### Dependencies and kernel headers

Build dependencies are installed automatically. `--test` and `--persistent`
install the headers for the running kernel and remove them again when the run
finishes; `--dkms` also installs the distro's generic header package so DKMS can
rebuild after kernel upgrades:

| Platform         | Installed by the scripts                                                     |
| ---------------- | ---------------------------------------------------------------------------- |
| Debian           | `build-essential`, `linux-headers-$(uname -r)`, `linux-headers-amd64`        |
| Ubuntu           | `build-essential`, `linux-headers-$(uname -r)`, `linux-headers-generic`      |
| Proxmox VE       | `build-essential`, `pve-headers` (meta — tracks every kernel update)         |
| Fedora/RHEL      | `gcc`, `make`, `kernel-devel-$(uname -r)`, `kernel-devel`                    |

Notes:
- On Ubuntu **HWE** kernels `linux-headers-generic` may not exist; a warning is
  printed and the usual `linux-headers-generic-hwe-<release>` advice applies.
- A Debian/Fedora box running a **custom kernel** with no matching headers
  package is refused with a clear error rather than half-installed.
- **SecureBoot**-enforced hosts refuse unsigned out-of-tree modules; disable
  SecureBoot (or sign the module) for the driver to load. Not handled by the
  scripts.
- RHEL 7 and older (`yum`) are out of scope; Fedora / RHEL 8+ use `dnf`.

Two more things worth knowing: the compiled module is tied to the exact kernel
it was built for, so always build on the target machine rather than copying
`.ko` files between systems. And once the module is up, standard tools like
`pwmconfig`/`fancontrol` or [CoolerControl](https://github.com/CoolerControl/CoolerControl)
can do the fan-speed curves for you.

## Releasing

The version is written down in exactly one place — the `MODULE_VERSION` string
in `driver-prototype/minisforum_n5_it5571.c`. `install.sh`, `setup-dkms.sh` and
`release.sh` all read it from there, so nothing can drift out of step.

`scripts/release.sh` builds the three artifacts a GitHub release needs:

```
dist/minisforum-n5-it5571-<version>.tar.gz        the source archive
dist/minisforum-n5-it5571-<version>.tar.gz.sha256  its checksum
dist/get.sh                                       the entrypoint, with the
                                                  version and checksum filled in
```

```bash
# 1. Bump MODULE_VERSION in driver-prototype/minisforum_n5_it5571.c, commit,
#    tag and push. release.sh refuses to run if the tag and the source disagree.
git tag -a v0.3.0 -m "v0.3.0: ..."
git push origin v0.3.0

# 2. Build the artifacts (they are written to dist/, which is gitignored).
scripts/release.sh

# 3. Publish the artifacts (the one-liner fetches get.sh).
gh release create v0.3.0 dist/minisforum-n5-it5571-0.3.0.tar.gz --title "v0.3.0"
gh release upload v0.3.0 dist/minisforum-n5-it5571-0.3.0.tar.gz.sha256 dist/get.sh
```

The archive ships only what the installer needs at runtime; `.gitattributes`
decides that. Everything must be committed before tagging, because `git archive`
reads committed files only, and `get.sh` refuses to install from an incomplete
archive.

The checksum file is there for people who want to verify by hand:

```bash
cd dist && sha256sum -c minisforum-n5-it5571-0.3.0.tar.gz.sha256
```

## Original documentation

Every upstream document was moved into `unraid-legacy/` untouched, so the full
context of the original project is still here:

- [Original README (English)](unraid-legacy/README.md) and the
  [简体中文](unraid-legacy/README.zh-CN.md) version — features, channel map,
  recommended companion tools, safety notes.
- [`README-FIRST`](unraid-legacy/README-FIRST.md) — the project's own
  start-here overview.
- [Reverse-engineering notes](unraid-legacy/docs/research/) — how the EC and
  its PWM/RPM registers were probed and understood.
- [Publication drafts](unraid-legacy/docs/publication/) — the Unraid
  Community Applications and support-thread packages.
- [`MANIFEST.md`](unraid-legacy/MANIFEST.md) — an index of every directory in
  the original archive.
- [Release notes](unraid-legacy/RELEASE-NOTES-v0.2.1.md).

## Disclaimer

This is an independent community effort, not affiliated with or endorsed by
Minisforum or ITE. The driver contains unverified factors and is provided
"as is"; you use it at your own risk. Upstream validated PWM control only on
`N5/F8NAA`. The `N5 PRO / F8NAB` support added here was tested on one machine
(sensors and PWM, but not the PCIe fan channel); other profiles are untested.
See the table in [`driver-prototype/README.md`](driver-prototype/README.md#supported-boards).
The full terms are in the
[original DISCLAIMER](unraid-legacy/DISCLAIMER.md).

## License

GPL-2.0. The repository does not redistribute vendor EC firmware or the
confidential IT5571 datasheet.