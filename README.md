# Built-in camera on ThinkPad X1 Carbon Gen 14 (Panther Lake) on Arch Linux

**Status: working.** 1920x1080 @ 30 fps in Teams, Slack and browsers, calibrated colors.

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

## Tested environment — read before applying elsewhere

All of this was built and verified on **one machine running
[Omarchy](https://omarchy.org)** (Arch-based) with the `linux-ptl` 7.1.3 kernel.
No guarantees on other distros, including other Arch derivatives. What carries
over and what does not:

- **Layer 1 (kernel modules)** is distro-agnostic: any distro whose kernel has
  IPU7 support (`intel-ipu7`, mainline since 6.17) but lacks the IMX471 series
  can build these sources against its own headers. Fedora users don't need it
  at all (the series is backported there).
- **Layer 2/3 overrides target Omarchy's `intel-ipu7-camera` package**
  (udev hide-rules, the WirePlumber drop-in, the v4l2-relayd chain). On a
  system without that package there is nothing to override — instead install
  `v4l2loopback` + `v4l2-relayd` yourself if you need the V4L2 compatibility
  layer, or skip layer 3 entirely if your applications can use PipeWire
  cameras.
- **Layer 4 (tuning file)** is libcamera-generic, but the calibration values
  are from this specific unit; treat them as a starting point.

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
  pipeline, NV12 1920x1080@30, tone and saturation set as `libcamerasrc` properties)
- `configs/97-libcamera-pipelines.conf` → systemd drop-in; sets
  `LIBCAMERA_PIPELINES_MATCH_LIST=simple`. **Do not skip this if you ever plug in a
  USB webcam.** Without it, libcamerasrc takes the first camera libcamera lists, the
  `uvcvideo` handler is enumerated before the internal `simple` pipeline, and relayd
  hijacks the webcam — configuring it as YUYV 1920x1080, a mode many webcams only
  advertise at 5 fps, and republishing those 5 fps as "Hardware ISP Camera" while the
  internal sensor never streams. The symptom is choppy video already in the app's local
  preview, before network and encoding. Selecting the sensor with `camera-name` in
  `ipu7.conf` instead looks simpler but is not: that value must survive three layers of
  backslash eating (systemd's `EnvironmentFile` unescaping, systemd's own `${VIDEOSRC}`
  expansion into the `sh -c` script, then `gst_parse_launch`) — measured here, 4
  backslashes in the file arrive as 1 in the process argv, and 8 is what makes it through — the
  count is not portable between machines (3 works on another user's), so verify it against the
  process argv if you pin the name. **Caveat:** the match list is not a permanent answer
  either. The IR camera (`\_SB_.LNK1`) is also on the `simple` pipeline, so once that sensor is
  enabled the list no longer narrows the selection to a single camera and `camera-name` is
  needed as well — belt and braces.
- `configs/99-dmabuf.conf` → systemd drop-in; the stock unit's device sandbox
  blocks `/dev/dma_heap`, which kills libcamera's software ISP
  ("Could not open any dma-buf provider")
- `configs/98-sync.conf` → systemd drop-in; adds `sync=false` to the `v4l2sink`.
  Without it, libcamerasrc's timestamps make the sink throttle to ~1-6 fps.
- keep `intel-ipu7-camera.service` enabled (it starts the relayd chain at boot)

All three drop-ins go into `/etc/systemd/system/v4l2-relayd@ipu7.service.d/`, followed by
`systemctl daemon-reload && systemctl restart v4l2-relayd@ipu7`.

Apps then see a working camera named "Hardware ISP Camera" (`/dev/video50`).

**Why 1080p and no `videoscale`:** libcamerasrc delivers 1920x1080 directly as a crop of
the sensor's single 1928x1088 mode, so scaling to 720p is pure added cost. Measured on the
input chain (GPU debayer, Panther Lake): 1080p without `videoscale` 26.8% of a core, versus
33.9% for 720p with `videoscale` + `videobalance`. The full relayd chain streaming 1080p30
measures ~14% of a core. If your CPU load looks far higher than that, check that you are on
the GPU debayer path — see Known limitations.

## Layer 4 — colors (tuning file)

libcamera's software ISP has no tuning for imx471 and renders a washed-out,
green-tinted image. `tuning/imx471.yaml` →
`/usr/share/libcamera/ipa/simple/imx471.yaml` fixes white balance with a
**diagonal-only** color matrix (hand-calibrated against a reference photo:
linear gains R=1.21, B=1.26).

Re-measured on libcamera 0.7.2 (2026-08-19) against a matte white target in mixed
office light, reading mean R/G and B/G on the target: no CCM gives R/G 0.921 / B/G 0.894
(green — AWB alone under-corrects), the shipped 1.21/1.26 gives 1.005/0.995.

Notes if you want to re-calibrate for your unit:
- **Do it.** The values above are from this module. Reports of the same values producing a
  magenta cast on other 21V7 units are consistent with module spread, not a regression.
- A/B tuning files without touching /usr:
  `LIBCAMERA_SIMPLE_TUNING_FILE=/path/candidate.yaml gst-launch-1.0 libcamerasrc ...`
  (or `LIBCAMERA_IPA_CONFIG_PATH=<dir>` with the file at `<dir>/simple/imx471.yaml`).
- The CCM is applied in the **linear** domain, but you measure the gamma-encoded output: an
  encoded ratio r means a linear error of r^2.2, so the gain you need is r^-2.2. Check:
  1.21^(1/2.2) = 1.090, which is exactly how much a 1.21 gain moved 0.921 → 1.005.
- Keep the matrix diagonal-only with all gains >= the G gain. Negative off-diagonal terms
  turn blown-out highlights magenta with this ISP (no highlight protection).
- For a **warmer** look raise the R gain (1.21 → 1.28 is a mild, natural step). Do not lower
  B to get there: measured here, lowering B turns the whole scene olive-green, because G then
  dominates. A mathematically neutral image reads colder than what phone and vendor ISPs
  show, since those bias warm on purpose — so a deliberate warm offset is a legitimate choice.
- **Tone is not in the tuning file.** libcamera's `Adjust` algorithm registers `Gamma`
  (0.1–10), `Contrast` (0–2) and `Saturation` (0–2, only when a `Ccm` block is present), so
  set them as `libcamerasrc` properties — see `configs/ipu7.conf`. Doing it there instead of
  with a `videobalance` element means the work happens in the linear domain via the CCM, at
  no extra CPU cost. Note this is not new in 0.7.2: `adjust.cpp` is identical in 0.7.1.
- **What really is ignored**: `exposure-value`, `brightness` and `sharpness`. The soft
  AGC/IPA registers no such controls (`agc.cpp` has no control map at all), so tone has to
  come from gamma/contrast. `colour-gains` and `awb-enable` are likewise not honored.
- `BlackLevel` must be present, as an **empty node**. libcamera only reads a single scalar
  `blackLevel` key (16-bit, shifted >>8); the per-channel `r/gr/gb/b` keys seen in example
  files have never been read (`blc.cpp` is identical in 0.7.1 and 0.7.2). An empty node
  instantiates automatic black-level estimation — measured here, that matters a lot:

  | tuning | YMIN | YLOW (10th pct) | YAVG |
  |---|---|---|---|
  | no `- BlackLevel:` node | 53 | 69 | 106 |
  | empty node (auto) | 0 | 28 | 75 |
  | explicit `blackLevel: 4096` | 1 | 30 | 79 |

  Without the node the algorithm is never instantiated, `DebayerParams::blackLevel` stays at
  0.0 and nothing is subtracted, so the shadow floor lifts into haze. This applies to the GPU
  path too — `debayer_egl.cpp` passes the value to the shader as a uniform. An explicit
  `blackLevel:` skips the auto-estimator, which in bright scenes converges near 16 anyway.
- This file is overwritten on every libcamera package upgrade; `scripts/fix-camera.sh`
  restores it (a pacman hook triggers it), until upstream ships a calibrated one.

## Factory calibration (experimental, unfinished)

The tuning file above is a hand-fitted diagonal. Intel ships something much better: binary
**AIQB** calibration blobs (CPFF format) containing the sensor's black level, AWB gain limits,
a white-point locus and **full 3x3 CCMs per illuminant**. Two sources:

- Intel's own HAL repo, free to download — `intel/ipu7-camera-hal`,
  `config/linux/ipu75xa/IMX471_BBG803N3_PTL.aiqb` is the IMX471 reference module for Panther
  Lake (`ipu7x/` holds the Lunar Lake set, `ipu8/` the next platform).
- The OEM Windows camera driver, which carries the modules the vendor actually fits — for
  `TBE20A0` there are three (`AAJH5-D`, `CBG802N3A`, `CJFPE90`). Search the Microsoft Update
  Catalog for the ACPI HID; unpack with `cabextract` (bsdtar's LZX support chokes on it).

`tools/fetch-factory-tuning.sh` downloads the Intel blob plus Javier Tia's `parse_aiqb.py`
(in review on libcamera-devel) and prints a ready tuning file. For the reference module it
yields five CCMs from 2738 K to 5844 K, all white-preserving (rows sum to 1.000).

**What libcamera 0.7.2 can use from it:** the `ccms` list and a scalar `blackLevel`. Nothing
else — `Awb` has no `init()` in 0.7.2, so `maxGainR`/`maxGainB`/`speed` are ignored (they need
master's pluggable AWB), and `Adjust` ignores tuning data entirely, so tone stays in
`configs/ipu7.conf` as `libcamerasrc` properties.

**The unsolved part is module identity.** The three modules' white points differ by about 8%
(daylight-end R/G: 0.4625 for BBG803N3, 0.4719 for AAJH5-D, 0.5043 for CBG802N3A), which is
large enough that picking the wrong blob defeats the purpose. On this SKU, guessing is
especially unwise: the fitted sensor is widely documented as an OV08X40 and is in fact an
IMX471. `tools/measure-raw.sh` measures the sensor's own raw white point for comparison — it
captures raw Bayer plus a viewfinder stream (raw alone leaves the AGC without stats, pinning
exposure at maximum) and `tools/raw-whitepoint.py` reports per-channel means and ratios.

What we have measured so far, and the traps found on the way:

- **Black level is 64 LSB, flat across all four channels** (dark frame with the privacy
  shutter closed: R=Gr=Gb=B=63.96). That is 4096 in libcamera's 16-bit convention. It must be
  subtracted before forming ratios, or a ~64 LSB pedestal drags them toward 1.0.
- **Chromatic lens shading makes the ratio position-dependent** — measured across a 4x4 grid
  of the same frame, R/G varies about 5%, comparable to the between-module difference. Use one
  fixed window (we use 380x260 at the frame centre) for every measurement point.
- **Clipping invalidates the ratios**, and it is easy to miss: a target at 48% mean brightness
  still had 2% of its green samples saturated because of a lamp hotspot. `raw-whitepoint.py`
  reports the clipped fraction per channel; require 0.000%.
- **An adjustable-CCT LED panel cannot identify the module.** Measured against the reference
  locus, our deviations were +3.0% at nominal 2900 K, +13.4% at 4000 K and +4.3% at 7000 K. A
  different module would shift the locus roughly uniformly; a hump in the middle is the
  signature of spectral mismatch — a bi-color LED mixes two phosphors into an SPD no blackbody
  resembles. Identification needs an illuminant close to what the factory used, i.e. real
  daylight.

So this section is a work in progress: the identity is not established, and the shipped
tuning file is still the diagonal. Note also that adopting a factory CCM means accepting
negative off-diagonal terms, which turn blown-out highlights magenta on this ISP — compare in
a scene with clipped highlights before switching. Independently reported (@jriff in the Omarchy
thread): with libcamera master's `bayes` AWB and the full factory locus, indoor results are
plausible but outdoor is worse than grey-world, because the search converges near 6600 K in
shade while the factory data stops at 5694 K and everything above it is extrapolated.

## Known limitations

- **Software ISP**: debayering runs on the GPU (EGL) and the rest on CPU — the
  IPU7's hardware ISP (PSYS) is not used by the open stack yet. Fine on Panther
  Lake at 1080p30, but not free: ~14% of a core for the full relayd chain. Make sure you
  are actually on the GPU path (look for `INFO eGL egl.cpp` in the log) — measured on the
  same 1080p30 pipeline, GPU debayer costs 28.5% of a core and the CPU debayer 72.6%, a
  2.5x difference that matters on battery. libcamera picks GPU when EGL is available;
  `LIBCAMERA_SOFTISP_MODE=cpu|gpu` overrides it.
- **2 MP, one mode**: the current imx471 driver implements a single binned
  1928x1088 mode; the sensor is natively 16 MP (4608x3456). More modes must come
  from the driver upstream.
- **Low light**: image gets dark (colors stay correct); the soft AGC maxes out
  and honors no manual override.
- **Faint colored horizontal lines** appear in the video on this stack (a pink and a blue
  line, most visible on flat bright areas). Known upstream issue, tracked as Red Hat
  bugzilla 2502786 — not caused by anything in this repo, so don't go hunting for it.
- The IR camera (`TBE20A1`, Windows Hello) needs out-of-tree work but is no longer a dead
  end: it is an ST VD55G1, and @jriff has four small patches that make it stream
  (ACPI match table for the DT-only vd55g1 driver, an ipu-bridge entry, the int3472 `vana`
  power-enable mapping, and a missing `V4L2_PIX_FMT_Y10` row in the ipu7-isys format table
  that makes mono sensors fail at STREAMON). See Related discussions. The IR emitter is not
  driven yet, so indoor LED-lit scenes come out near-black.

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
tools/     factory-calibration fetch/parse + raw white-point measurement (see above)
configs/   v4l2-relayd config + systemd drop-ins (incl. camera selection) + WirePlumber override
tuning/    libcamera soft-ISP tuning file for imx471
```

## License

Kernel module sources and patches: GPL-2.0 (see LICENSE), original authorship
preserved in the mbox patches. Tuning file: CC0. Docs: CC-BY-4.0.

## Related discussions

Ongoing dialogue around this camera, with more detail and history:

- **Omarchy issue** — the main troubleshooting thread, incl. Lenovo's Linux
  lead (@mrhpearson): https://github.com/basecamp/omarchy/issues/6000
- **Red Hat bugzilla 2483180** — the IMX471 enablement bug (Kate Hsuan),
  Fedora backport status: https://bugzilla.redhat.com/show_bug.cgi?id=2483180
- **Lenovo Linux forum thread** — history of the (initially wrong) firmware
  theory, now corrected + solved:
  https://forums.lenovo.com/t5/Other-Linux-Discussions/X1-Carbon-Gen-14-21V7-OLED-MIPI-camera-OV08X40-IPU7-not-working-on-Linux-%E2%80%94-firmware-LCHS/m-p/10033620
- **Kernel patch series** (linux-media, applied, in linux-next):
  https://lore.kernel.org/linux-media/20260629074026.35490-1-hpa@redhat.com/
- **IR camera (ST VD55G1)** — patches, identification evidence and capture recipe by
  @jriff: https://github.com/jriff/x1c14-ir-vd55g1 , tracked as Red Hat bugzilla
  https://bugzilla.redhat.com/show_bug.cgi?id=2509956
- **`imx471-dkms-git` (AUR)** — packages the same upstream series as DKMS with per-kernel
  variants, an alternative to building from `src/` here. Note its bundled tuning file is
  calibrated from a different module and renders pink on 21V7; use `tuning/imx471.yaml`
  from this repo instead: https://aur.archlinux.org/packages/imx471-dkms-git
- **Colored horizontal lines** (softISP, upstream):
  https://bugzilla.redhat.com/show_bug.cgi?id=2502786

## Credits

- Kate Hsuan (Red Hat) — imx471 driver + ipu-bridge enablement
  (RH bugzilla #2483180)
- Everyone in Omarchy issue basecamp/omarchy#6000
