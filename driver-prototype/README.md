# minisforum_n5_it5571 kernel module

An `hwmon` driver for the ITE IT5571 embedded controller in the Minisforum N5
family. It exposes four fan channels (CPU, SSD, HDD, PCIe), four temperature
sensors (CPU, System, Board, Ambient) and, only if you ask for it, four PWM
controls.

## Supported boards

The module loads only when the DMI strings match one of these:

| `product_name` | `board_name` | Model  | Tested on real hardware |
| -------------- | ------------ | ------ | ----------------------- |
| `N5`           | `F8NAA`      | N5     | Yes, by upstream: sensors and PWM (BIOS 1.04) |
| `N5 PRO`       | `F8NAA`      | N5 Pro | No |
| `N5 PRO`       | `F8NAB`      | N5 Pro | Yes, by this fork: sensors and PWM; PCIe fan channel not tested (no PCIe card installed) |
| `N5A` / `N5 AIR` | `F8NAB`    | N5 Air | No |

"Tested" means someone confirmed it on real hardware. Untested boards are
best-effort profiles: check that temperatures and RPM look right before
enabling PWM writes, and consider reporting your results.

Check yours:

```bash
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name
```

## Build

```bash
make
make clean
```

This needs the headers for the running kernel. The resulting `.ko` only works
on the kernel it was built for.

## Load and unload

Read-only (default, no PWM nodes):

```bash
sudo insmod minisforum_n5_it5571.ko
```

With PWM writes:

```bash
sudo insmod minisforum_n5_it5571.ko enable_write=1
```

Unload (returns touched channels to automatic mode):

```bash
sudo rmmod minisforum_n5_it5571
```

Changing the setting needs an unload and a load.

Verify:

```bash
sensors
dmesg | grep minisforum
```

**Enable writes only after the temperature and RPM readings look right.** If a
fan stops, runs unexpectedly or a channel looks mismatched, unload the module.

## force=1 (unsupported)

`force=1` loads the module on a board with no DMI match, read-only. This is
unsupported and at your own risk. Adding `enable_write=1` also enables PWM
writes on that unknown board, which is strongly discouraged and can damage
hardware. The installer scripts never offer it.

## Installing properly

For a persistent or DKMS install, use [`scripts/install.sh`](../scripts/install.sh)
(`--enable-write` passes `enable_write=1`).
