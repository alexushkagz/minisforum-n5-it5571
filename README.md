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

Once the module is up, standard tools like `pwmconfig`/`fancontrol` or
[CoolerControl](https://github.com/CoolerControl/CoolerControl) can do the
fan-speed curves for you.

## Installing

Works on Debian/Ubuntu (stock kernel), Proxmox VE (`-pve` kernel) and
Fedora/RHEL 8+ (`dnf`). The installer detects your distro and kernel and
installs any missing build dependencies automatically.

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
- `--test` (default) — build and load into the running kernel. Nothing is
  persisted; a reboot returns to BIOS control.
- `--persistent` — install into `/lib/modules/<kernel>/extra` and load on boot.
  Kernel-specific: **rerun it after every kernel update**, or use `--dkms`.
- `--dkms` — register with DKMS, so the module is rebuilt automatically on
  every kernel update.
- `--uninstall` — detect what is installed and undo it. Copies left for other
  kernels are listed, not removed.
- `--help`, `-h` — show usage.

Flag:
- `--enable-write` — load with PWM writes enabled (read-only otherwise).
  Applies to `--test`, `--persistent` and `--dkms`.

All modes unload an already-loaded copy first, so rerunning with
`--enable-write` reloads the module with the new setting.

The compiled module only works on the exact kernel it was built for,
so build on the target machine instead of copying .ko files between systems.

`setup-dkms.sh` and `uninstall.sh` can also be run directly. `uninstall.sh`
takes no arguments and removes every install mode, including all registered
DKMS versions; it is what `install.sh --uninstall` calls.

### Dependencies and kernel headers

Only what is missing is installed. `--test` and `--persistent` need the
compiler and the headers for the running kernel, and remove exactly the
packages they installed when they finish (no `autoremove`). `--dkms` also
installs the distro's header metapackage and `dkms`, and keeps everything, so
DKMS can rebuild after kernel updates.

| Platform         | Headers for the running kernel                          | Metapackage (`--dkms`)                              | Compiler             |
| ---------------- | ------------------------------------------------------- | --------------------------------------------------- | -------------------- |
| Proxmox VE       | `proxmox-headers-<kver>`, else `pve-headers-<kver>`     | `proxmox-default-headers`, else `pve-headers`       | `build-essential`    |
| Debian           | `linux-headers-<kver>`                                  | `linux-headers-amd64` (`-amd64` kernels only)       | `build-essential`    |
| Ubuntu           | `linux-headers-<kver>`                                  | `linux-headers-generic` (`-generic` kernels only)   | `build-essential`    |
| Fedora/RHEL 8+   | `kernel-devel-<kver>`                                   | `kernel-devel-matched`, else `kernel-devel`         | `gcc`, `make`        |

Notes:
- On Ubuntu **HWE**, cloud and other non-`-generic` kernels (and Debian kernels
  not ending in `-amd64`) the metapackage is not installed automatically and a
  warning is printed. Install matching headers yourself so DKMS can rebuild.
- Headers already present in `/lib/modules/<kver>/build` are used as is, even
  from a custom kernel.
- **SecureBoot**-enforced hosts refuse unsigned out-of-tree modules; disable
  SecureBoot (or sign the module) for the driver to load. Not handled by the
  scripts.

## Repository layout

Keeping the original structure made it easy to track upstream while giving the
Proxmox parts their own place:

- **`driver-prototype/`** — the driver itself: `minisforum_n5_it5571.c` and the
  kernel module `Makefile` (see its [README](driver-prototype/README.md) for
  manual build and load). The path mirrors the upstream repo exactly, so the
  driver can be merged forward cleanly as the original project evolves.
- **`scripts/`** — the installer and its helpers:
  - `install.sh` builds and installs the driver from the sources next to it, so
    it runs either from a clone or from inside an unpacked release.
  - `get.sh` is the download entrypoint: it fetches a release, verifies its
    checksum and hands over to `install.sh`.
  - `setup-dkms.sh` and `uninstall.sh` are the DKMS installer and the
    standalone uninstaller.
  - `lib/` holds internal helpers: shared functions and constants, and the
    distro/kernel-header logic.
  - `release.sh` builds the release artifacts (see [Releasing](#releasing)).
- **`unraid-legacy/`** — everything Unraid-only from the original repository,
  kept unchanged for reference. Nothing in it is needed to run the driver.
- **`LICENSE` / `LICENSES/`** — the GPL-2.0 material covering the driver
  source.

## Releasing

The version is written down in exactly one place — the `MODULE_VERSION` string
in `driver-prototype/minisforum_n5_it5571.c`. `setup-dkms.sh` and `release.sh`
read it from there, so nothing can drift out of step.

`scripts/release.sh` builds the three artifacts a GitHub release needs. It reads
everything (driver version, archive, `get.sh` template) from the tagged commit,
not from the working tree, so commit and tag first:

```
dist/minisforum-n5-it5571-<version>.tar.gz        the source archive
dist/minisforum-n5-it5571-<version>.tar.gz.sha256  its checksum
dist/get.sh                                       the entrypoint, with the
                                                  version and checksum filled in
```

## Original documentation

The original upstream documents live in `unraid-legacy/`, untouched:

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
