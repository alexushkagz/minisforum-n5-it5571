# Minisforum N5 fan driver for Proxmox VE

The Minisforum N5-family NAS has no fan control in the Linux kernel: all the
work is done by an embedded controller (ITE IT5571) that only the BIOS knows
how to talk to. This driver gives that controller a standard `hwmon`
interface, so on Proxmox you can finally read the temperatures and take manual
control of the fans instead of letting the firmware decide everything.

It is a fork of the community driver by
[ltdstudio](https://github.com/ltdstudio/minisforum-n5-it5571) — the guy
who reverse-engineered the EC and originally shipped this as an Unraid plugin.
This fork keeps that driver intact, but adapts it to install and run as a
plain kernel module on Proxmox VE or any other general debian-based distro, and adds official support for one hardware
combination the upstream DMI check did not yet know about.

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

- **`driver-prototype/`** — the driver itself: `minisforum_n5_it5571.c`, the
  kernel module `Makefile`, and the DKMS helpers `setup-dkms.sh` /
  `remove-dkms.sh`. The path mirrors the upstream repo exactly, so the driver
  can be merged forward cleanly as the original project evolves.
- **`unraid-legacy/`** — everything Unraid-only from the original repository,
  moved here unchanged for reference: the plugin file, the WebGUI sources, the
  `.txz` and kernel build scripts, the reverse-engineering tools, the
  screenshots, and all the original documentation. Nothing in this folder is
  needed to run the driver on Proxmox.
- **`LICENSE` / `LICENSES/`** — the GPL-2.0 material covering the driver
  source.

## What the driver does

Loaded, the module registers an `hwmon` device with four fan channels — CPU,
SSD, HDD group and the PCIe fan (that last one has no tachometer signal on the
board, so it honestly reports 0 RPM) — and four EC temperature sensors: CPU,
System, Board and Ambient.

Each PWM channel can be switched between the EC's automatic curve and manual
control, and the driver restores the automatic mode for the channels it
actually touched when it is unloaded. On hardware like ours, where upstream had
not yet validated the DMI pair, the module starts in read-only mode: PWM
writes are only enabled after you deliberately pass `experimental_write=1`
once the sensor readings look right.

## Installing on Proxmox

Run the DKMS helper directly on the Proxmox host:

```bash
sudo ./driver-prototype/setup-dkms.sh
```

It installs the kernel headers, builds the module for the running kernel,
registers it with DKMS — so it is rebuilt automatically after kernel updates —
and loads it with `experimental_write=1`. To remove it again:

```bash
sudo ./driver-prototype/remove-dkms.sh
```

Two things worth knowing: the compiled module is tied to the exact kernel it
was built for, so always build on the target machine rather than copying
`.ko` files between systems. And once the module is up, standard tools like
`pwmconfig`/`fancontrol` or [CoolerControl](https://github.com/CoolerControl/CoolerControl)
can do the fan-speed curves for you.

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
"as is"; you use it at your own risk. Upstream has fully validated only the
`N5/F8NAA` profile — the `N5 PRO / F8NAB` support added here is experimental
until the validation checklist has been completed. The full terms are in the
[original DISCLAIMER](unraid-legacy/DISCLAIMER.md).

## License

GPL-2.0. The repository does not redistribute vendor EC firmware or the
confidential IT5571 datasheet.