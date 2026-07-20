# Built-in camera on ThinkPad X1 Carbon Gen 14 (Panther Lake) on Arch Linux

**Status: working.** 1280x720 @ 30 fps in Teams, Slack and browsers, calibrated colors.

This repo documents how to enable the built-in MIPI camera on the Lenovo ThinkPad
X1 Carbon Gen 14 (tested: type 21V7, 2.8K OLED SKU, BIOS 1.14) under Arch Linux
(kernel `linux-ptl` 7.1.3), and — maybe more importantly — which wrong turns you
can skip.

**⚠️ This is a workaround, not the destination.** Everything here is an interim
solution until proper support exists end to end; each section notes what will
make it obsolete. The real fix consists of, in order:

1. **Kernel**: the IMX471 sensor driver series merged mainline and shipped by
   distro kernels (in flight on linux-media — this repo just builds it early).
2. **ISP**: better image processing. Note that the hardware ISP (PSYS) is a
   dead end for the open stack: Intel considers its interface and algorithms
   proprietary and never mainlined PSYS for IPU6 or IPU7 — upstream libcamera's
   official direction for IPU7 is the simple pipeline + software ISP, i.e.
   exactly what this setup runs. The realistic path to better quality is the
   ongoing softISP work (GPU acceleration, FOSS sensor calibration and CCM
   color correction, lens shading, improved 3A — see the FOSDEM 2026 softISP
   status talk by Bryan O'Donoghue and Hans de Goede), which will eventually
   obsolete the hand-made tuning file below.
3. **Desktop**: applications consuming cameras via PipeWire/libcamera natively,
   removing the v4l2loopback relay layer entirely.

If you can contribute to any of those, that helps far more than polishing this
workaround.

## TL;DR

- The sensor is a **Sony IMX471** behind the Lenovo-specific ACPI HID **`TBE20A0`**
  — *even on the OLED SKU that public sources claim uses an OmniVision OV08X40*.
  We verified on the wire: CCS model-id register `0x0016` reads `0x0471`.
- No driver in kernel 7.1.3 matches `TBE20A0`, so the sensor is never probed:
  `intel-ipu7: no subdev found in graph`.
- Fix = Kate Hsuan's (Red Hat) IMX471 driver series + small local adaptations +
  desktop plumbing (pipewire-libcamera and/or a re-purposed v4l2-relayd), plus a
  hand-made libcamera tuning file for decent colors.

## What does NOT work / wrong turns we took (so you don't have to)

1. **It is not a firmware/BIOS lock.** The hidden BIOS "CVS Support" setting
   (Setup var offset 0x3D9), the `LCHS`/`L2EN` ACPI flags and the disabled
   `OVTI08F4` ACPI node all belong to *other, unused* camera paths (Intel CVS /
   "Computer Vision"). The enabled camera node `TBE20A0:00` (`_STA=0xF`) is there
   all along — check `/sys/bus/acpi/devices/TBE20A0:00/status` first.
2. **It is not the OV08X40.** Binding `ov08x40` to `TBE20A0` probes the chip but
   fails chip-id (and its 5 ms post-reset delay is too short anyway — the sensor
   needs ~50 ms before it ACKs on I2C).
3. **The IMX471 patch series is NOT "for a different SKU only".** RH bug 2483180
   was filed for a 21V8 non-OLED unit, but the OLED 21V7 has the same sensor.
4. **`QCFG/XCFG/DCFG/CCFG` ACPI methods are SoundWire audio**, not camera power
   (naming collision on `LNK0`). The camera power path is a standard INT3472
   discrete design and works out of the box (avdd + reset GPIO + 19.2 MHz DSM clock).
5. **`gst-launch v4l2src` is a bad test client for v4l2loopback** — it fails
   buffer allocation even when the chain works. Test with
   `v4l2-ctl -d /dev/video50 --stream-mmap --stream-count=90` instead.

## Layer 1 — kernel modules

Out-of-tree build of two modules against your running kernel, from the upstream
series "[PATCH v6 0/4] Add Sony IMX471 camera sensor driver" by Kate Hsuan
(linux-media, msgid `20260629074026.35490-1-hpa@redhat.com`,
https://lwn.net/Articles/1071230/):

- **`imx471.ko`** — the new sensor driver (patch 4/4). One local change while
  patch 3/4 is not in your kernel: in `imx471_supply_name[]`, rename `"vana"` to
  `"avdd"` (stock `int3472-discrete` registers the power rail under that name).
- **`ipu-bridge.ko`** — add `IPU_SENSOR_CONFIG("TBE20A0", 1, 200000000)`
  (patch 2/4) to your kernel's `drivers/media/pci/intel/ipu-bridge.c`.

Ready-to-build sources are in `src/` (kernel 7.1.3 + the series + the local
`avdd` patch already applied; provenance in `patches/upstream/` and
`patches/local/`). Quick start:

```
sudo bash scripts/install.sh    # builds against the running kernel, installs, depmod
reboot
```

Optional but recommended: `scripts/fix-camera.sh` + `scripts/x1c14-camera.hook`
(adjust its Exec path) make pacman rebuild everything automatically on every
kernel/libcamera update — and self-clean once the driver lands upstream.

Expected after reboot:

```
intel-ipu7 0000:00:05.0: Found supported sensor TBE20A0:00
intel_ipu7_isys ...: bind imx471 0-001a nlanes is 4 port is 0
```

**You must rebuild after every kernel update** until the series is merged
(check: `modinfo imx471` on a new kernel — if it exists, delete the out-of-tree
copies and this layer is done).

## Layer 2 — libcamera / PipeWire

```
pacman -S libcamera libcamera-tools pipewire-libcamera gst-plugin-libcamera
```

Verify with `cam --list` (as root first). Two vendor roadblocks ship in the
`intel-ipu7-camera` package (Omarchy default) and must be overridden:

- `/usr/lib/udev/rules.d/71-ipu7-hide-isys.rules` strips user access from the
  ISYS video nodes → mask it: `touch /etc/udev/rules.d/71-ipu7-hide-isys.rules`
- `/usr/share/wireplumber/wireplumber.conf.d/disable-libcamera.conf` disables
  WirePlumber's libcamera monitor → shadow it with
  `configs/wireplumber-enable-libcamera.conf` in `/etc/wireplumber/wireplumber.conf.d/`

After a wireplumber restart, PipeWire-native apps see "Built-in Front Camera".

## Layer 3 — classic V4L2 apps (Teams, Slack, Chromium…)

Most apps do not use PipeWire cameras yet; they enumerate `/dev/video*`. Re-use
the `v4l2-relayd` + `v4l2loopback` chain that `intel-ipu7-camera` ships, but feed
it from libcamera instead of Intel's HAL (which requires a sensor config that
does not exist for this machine):

- `configs/ipu7.conf` → `/etc/v4l2-relayd.d/ipu7.conf` (`libcamerasrc`-based
  pipeline, NV12 1280x720@30, saturation boost via `videobalance`)
- `configs/99-dmabuf.conf` → systemd drop-in; the stock unit's device sandbox
  blocks `/dev/dma_heap`, which kills libcamera's software ISP
  ("Could not open any dma-buf provider")
- `configs/98-sync.conf` → systemd drop-in; adds `sync=false` to the `v4l2sink`.
  Without it, libcamerasrc's timestamps make the sink throttle to ~1-6 fps.
- keep `intel-ipu7-camera.service` enabled (it starts the relayd chain at boot)

Apps then see a working camera named "Hardware ISP Camera" (`/dev/video50`).

## Layer 4 — colors (tuning file)

libcamera's software ISP has no tuning for imx471 and renders a washed-out,
green-tinted image. `tuning/imx471.yaml` →
`/usr/share/libcamera/ipa/simple/imx471.yaml` fixes white balance with a
**diagonal-only** color matrix (hand-calibrated against a reference photo:
linear gains R=1.21, B=1.26).

Notes if you want to re-calibrate for your unit:
- Iterate without touching /usr via `LIBCAMERA_IPA_CONFIG_PATH=<dir>` with the
  file at `<dir>/simple/imx471.yaml`.
- The CCM is applied in the **linear** domain: to change an encoded (sRGB) ratio
  by a factor k, use gain k^2.2.
- Keep the matrix diagonal-only with all gains >= the G gain. Negative
  off-diagonal terms turn blown-out highlights magenta with this ISP (no
  highlight protection).
- The soft ISP **ignores** all runtime color/exposure controls
  (`colour-gains`, `awb-enable`, `exposure-value`, framerate hints) — the tuning
  file is the only lever.
- This file is overwritten on every libcamera package upgrade; re-copy it until
  upstream ships a calibrated one.

## Known limitations

- **Software ISP**: debayering runs on the GPU (EGL) and the rest on CPU — the
  IPU7's hardware ISP (PSYS) is not used by the open stack yet. Fine on Panther
  Lake at 720p30, but not free.
- **2 MP, one mode**: the current imx471 driver implements a single binned
  1928x1088 mode; the sensor is natively 16 MP (4608x3456). More modes must come
  from the driver upstream.
- **Low light**: image gets dark (colors stay correct); the soft AGC maxes out
  and honors no manual override.
- The IR camera (`TBE20A1`, Windows Hello) has no Linux driver at all.

### Why the tuning file has only ONE color-temperature entry

We measured a white target under an adjustable key light (2900K–6993K) and built
a proper multi-`ct` CCM list. Verification showed it must NOT be shipped: the
simple IPA's color-temperature estimator assigns a HIGH ct to tungsten scenes,
so low-ct entries are never selected and high-ct entries get applied to warm
light, making it visibly worse (measured: B/G dropped from 0.88 to 0.76 under
2900K light with a 7000K entry present). Until the soft ISP's ct estimation
improves upstream, keep a single entry. Measured residuals with the single
entry: neutral within ~4% from 4000K to 6500K, warm cast retained under
tungsten (subjectively fine), −4.5% red at 7000K (negligible).

## Repository layout

```
src/       ready-to-build module sources (kernel 7.1.3 + series + local patch)
patches/   provenance: upstream v6 series (mbox) + our local delta
scripts/   install/revert, kernel-update automation (fix-camera.sh + pacman hook)
configs/   v4l2-relayd config + systemd drop-ins + WirePlumber override
tuning/    libcamera soft-ISP tuning file for imx471
```

## License

Kernel module sources and patches: GPL-2.0 (see LICENSE), original authorship
preserved in the mbox patches. Tuning file: CC0. Docs: CC-BY-4.0.

## Credits

- Kate Hsuan (Red Hat) — imx471 driver + ipu-bridge enablement
  (RH bugzilla #2483180)
- Everyone in Omarchy issue basecamp/omarchy#6000
