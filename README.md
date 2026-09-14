# Software fan control on the Dell Precision 3650 Tower (Linux)

**TL;DR** — The Dell Precision 3650 Tower is not in the `dell-smm-hwmon` fan-control whitelist, so the EC ignores every `pwm` write and the BIOS keeps full control of the fans. Adding **one DMI entry** (8 lines) with a known SMM code pair unlocks **manual control of all three fans** (CPU, front, top), three levels each, with real tachometer feedback. Both known pairs work on this machine (`0x30a3/0x31a3` and `0x34a3/0x35a3`); the patch uses `0x30a3/0x31a3`, which matches recent Dell OEM software. Tested on BIOS 1.48.0, Ubuntu 26.04.1, kernels 7.0.0-30 and 7.0.0-31, using the driver's **WMI-SMM backend**.

**Upstream status:** patch submitted to `linux-hwmon` — [v1](https://lore.kernel.org/linux-hwmon/20260913112925.11393-1-patpep@me.com/) (Acked-by Pali Rohár, the driver maintainer), [v2](https://lore.kernel.org/linux-hwmon/20260914080955.87925-1-patpep@me.com/) switching to `0x30a3/0x31a3` at Armin Wolf's request. Until it lands in your distro's kernel, the DKMS recipe below does the job.

This repo contains the patch, a DKMS recipe so the module survives kernel updates, the measured fan tables, the EC behaviours we mapped, and two helper scripts (`perf-mode`, `fan-daemon`).

> ⚠️ Disabling BIOS fan control hands thermal safety to *your* software. Read [Safety](#safety) before using this.

---

## Tested hardware / software

| Item | Value |
|---|---|
| Machine | Dell Precision 3650 Tower, i7-10700, BIOS 1.48.0, DMI product name `Precision 3650 Tower` |
| Fans | CPU blower (Dell KTDJC on 125 W heatsink 93XV1), front 120×38 mm Delta (Dell HHCM0), top 92 mm (Arctic P9 Max on the `FAN SYS` header) |
| OS / kernel | Ubuntu 26.04.1 LTS, kernel 7.0.0-30 / 7.0.0-31 (`dell-smm-hwmon` with WMI-SMM backend, GUID `F1DDEE52-063C-4784-A11E-8A06684B9B01`) |
| Secure Boot | Off (DKMS modules are MOK-signed anyway) |

## The problem

Stock `dell-smm-hwmon` on this machine (loaded normally, **without** `force=1`) exposes `fan1..3_input`, `pwm1..3` and `pwm1..3_enable`, but:

- writing `255` to `pwmX` is overwritten by the EC within a second (reads back `128`), RPM unchanged;
- writing `2` to `pwmX_enable` returns `EINVAL`;
- `dell-pc` (platform profiles) → `No such device`; `libsmbios` is gone from recent distros; user-space SMM tools (`dell-fan-mon`, `dellfan`) get `-1` because the legacy SMM port does not answer on this platform — only the WMI path works.

Root cause: the machine is not in `i8k_whitelist_fan_control[]` in `drivers/hwmon/dell-smm-hwmon.c`, so the driver has no "disable BIOS fan control" SMM code for it.

## The fix

Add the Precision 3650 Tower to the whitelist. Both known code pairs were tested and work (`I8K_FAN_34A3_35A3`, the OptiPlex 7000 pair, and `I8K_FAN_30A3_31A3`); the patch uses `I8K_FAN_30A3_31A3` since it is what recent OEM software uses. See [`dell-smm-hwmon-3650.patch`](dell-smm-hwmon-3650.patch):

```c
	{
		.ident = "Dell Precision 3650 Tower",
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "Dell Inc."),
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "Precision 3650 Tower"),
		},
		.driver_data = (void *)&i8k_fan_control_data[I8K_FAN_30A3_31A3],
	},
```

After loading the patched module, `dmesg` shows `dell_smm_hwmon: Enabling support for setting automatic/manual fan control`, and the hwmon device exposes a single, global `pwm1_enable` (`1` = manual, `2` = give control back to the BIOS) plus `pwm1`, `pwm2`, `pwm3`.

**Do not load the module with `force=1`** on this machine: `force` selects the legacy SMM backend, which does not answer here (zero fans). Load it plainly; it binds through WMI.

### Install with DKMS (survives kernel updates)

```bash
sudo apt install -y dkms build-essential linux-headers-generic
# get the driver source matching your kernel series (example: v7.0) and apply the patch
mkdir -p ~/dell-smm && cd ~/dell-smm
wget -O dell-smm-hwmon.c "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/hwmon/dell-smm-hwmon.c?h=v7.0"
patch -p3 dell-smm-hwmon.c < /path/to/dell-smm-hwmon-3650.patch     # or insert the 8 lines after the OptiPlex 7000 entry
printf 'obj-m := dell-smm-hwmon.o\n' > Makefile
sudo mkdir -p /usr/src/dell-smm-hwmon-3650-1.0
sudo cp dell-smm-hwmon.c Makefile /usr/src/dell-smm-hwmon-3650-1.0/
sudo cp /path/to/dkms/dkms.conf /usr/src/dell-smm-hwmon-3650-1.0/
sudo dkms add -m dell-smm-hwmon-3650 -v 1.0
sudo dkms install -m dell-smm-hwmon-3650 -v 1.0 -k "$(uname -r)"
echo dell-smm-hwmon | sudo tee /etc/modules-load.d/dell-smm.conf
sudo modprobe -r dell-smm-hwmon; sudo modprobe dell-smm-hwmon
dmesg | grep "Enabling support"            # must appear
modinfo -F filename dell-smm-hwmon         # must be .../updates/dkms/...
```

Gotcha we hit: if a newer kernel was already installed but not yet booted when you create the DKMS module, build for it explicitly (`dkms install ... -k <version>`) or it will boot with the stock module. Keep `linux-headers-generic` installed so DKMS can rebuild at every kernel update.

## Results

### Fan levels (measured, `fanX_input` = tachometer RPM)

The EC offers **three levels per fan** — there is no continuous 0–100 %. Level 1 is essentially the idle speed. Identical results with both code pairs.

| hwmon | Fan | Level 0 (`0`) | Level 1 (`128`) | Level 2 (`255`) | EC target at level 2 | Noise |
|---|---|---|---|---|---|---|
| `pwm1`/`fan1` | CPU blower (KTDJC) | 825 (floor) | 825 | **4 441** | 4 450 | quiet |
| `pwm2`/`fan2` | Front Delta 120×38 (HHCM0) | 584 | ~1 000 | **3 270** | 3 300 | loud (industrial fan) |
| `pwm3`/`fan3` | Top Arctic P9 Max | 774 | 891 | **3 200** | 3 200 | quiet |

- Each fan reaches its target in 20–40 s (the CPU blower is the slowest) and holds it within ±10 RPM.
- `pwmX` reads back the level the EC has *accepted* (it shows `255` a few seconds after the write); `fanX_target` shows the nominal RPM of the current level.
- Manual mode is **global**: `echo 1 > pwm1_enable` makes the BIOS release **all** fans, including the CPU fan. Fans keep their last commanded level — always write all three. `echo 2 > pwm1_enable` returns everything to the BIOS curve.

### EC behaviours worth knowing (measured with stress-ng, RAPL, coretemp)

| Behaviour | Measured |
|---|---|
| BIOS fan curve | Lazy: CPU fan starts ramping at ~80 °C, ~60 s lag. Front fan follows an ambient/PCIe-zone sensor only (never moved at 90 °C CPU / 145 W GPU / 11 days idle). |
| Sustained package power cap | **90 W after ~30–40 s** above 90 W, **regardless of temperature** (same at 63 °C with all fans at 100 %). Set by the EC over PECI; MSR/MMIO PL1 values above 90 W change nothing. |
| Thermal penalty | Around 87–90 °C the EC cuts the CPU to **65 W and keeps it there** for a while after cooling down. Short bursts that reach that zone are counter-productive. |
| Burst | 138–140 W at 4.6 GHz all-core for ~20–30 s (i7-10700, PL2 = 150 W). |
| HWP | Ubuntu Server's default EPP `balance_performance` capped the CPU at 3.6–3.9 GHz under load; `performance` gives 4.4–4.6 GHz. |
| `FanCtrlOvrd` (BIOS "Fan Control Override") | Togglable **instantly from Linux, no reboot**, via `dell-wmi-sysman`: all fans to 100 % (4 720 / 3 570 / 3 860 RPM). |

## Scripts

- [`scripts/perf-mode`](scripts/perf-mode) — `on` (BIOS override 100 % + PL2 140 W), `off` (fans back to BIOS, PL2 115 W), `fans <cpu> <front> <top>` (levels 0/1/2), `fans auto`, `status`.
- [`scripts/fan-daemon`](scripts/fan-daemon) — systemd-friendly loop: **auto** by default (BIOS curve, which is fine for the CPU); **gpu** mode when the GPU is ≥ 70 °C for 30 s (front + top to max, CPU fan level 1); **hot** mode when the CPU is ≥ 88 °C, or ≥ 78 °C while in gpu mode (all fans max). Hysteresis, does nothing when the BIOS override is active, returns fans to the BIOS on stop/crash. Thresholds are variables at the top.
- [`scripts/cpu-perf.sh`](scripts/cpu-perf.sh) — boot-time settings: EPP `performance`, PL1/PL2 via RAPL (optionally with [setPL](https://github.com/horshack-dpreview/setPL) to neutralise the MMIO limit), NVIDIA persistence + power limit.

Example units are in [`scripts/systemd/`](scripts/systemd/).

## Safety

- In manual mode **nothing** manages the CPU fan except your software. A crashed daemon leaves fans at their last level. Keep a return-to-auto in your exit path (`echo 2 > pwm1_enable`), use `Restart=always`, and watch temperatures during tests.
- Remaining hardware protections: the EC power penalty (~87 °C) and Intel's thermal throttle at 100 °C — they will save the CPU, not your performance.
- The SMM "disable BIOS fan control" codes are undocumented by Dell; the kernel documentation warns they can have side effects on some machines. On this machine, over two weeks of use, none were observed. Your mileage may vary — test with the machine idle first.
- Loading an out-of-tree module taints the kernel (harmless, but expected).

## Status

- [x] Patch tested on Precision 3650 Tower (BIOS 1.48.0), kernels 7.0.0-30 and 7.0.0-31, DKMS, survives reboot and kernel update.
- [x] Patch submitted to `linux-hwmon`: [v1 (2026-09-13, Acked-by Pali Rohár)](https://lore.kernel.org/linux-hwmon/20260913112925.11393-1-patpep@me.com/), [v2 (2026-09-14, `0x30a3/0x31a3`)](https://lore.kernel.org/linux-hwmon/20260914080955.87925-1-patpep@me.com/).
- [ ] Merged upstream.
- [ ] Reports from other 3650 owners / other BIOS versions welcome (open an issue with `dmidecode -s system-product-name`, BIOS version, kernel, and the `dmesg` line).

Not tested: Precision 3630 / 3640 / 3660 / 3680, OptiPlex 7080. The OptiPlex 7090 has since been whitelisted in `hwmon-next` as well.

## Credits

- Pali Rohár (driver maintainer) and Armin Wolf (WMI-SMM backend, OptiPlex 7000 entry) for the quick review.
- The Linux `dell-smm-hwmon` documentation (https://docs.kernel.org/hwmon/dell-smm-hwmon.html).
- [horshack-dpreview/setPL](https://github.com/horshack-dpreview/setPL) for the MSR/MMIO power-limit tool.

## License

The patch (`dell-smm-hwmon-3650.patch`) is a modification of the Linux kernel and is licensed under **GPL-2.0-only**, like the driver. The scripts in `scripts/` are released under the **MIT** license.
