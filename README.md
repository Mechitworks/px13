# PX13 rebase onto cachyos-7.2.9-2

Working tree: `~/px13-work/`

```
linux-cachyos-px13/          AUR clone, rebased PKGBUILD + 19 patches (pkgver 7.2.9-1)
asus-proart-px13-quirks/     AUR clone, pkgver bumped to 7.2.9 (lockstep only)
series-v2/                   the rebased patch series (source of truth for the PKGBUILD)
rebase/cachyos-7.2.9-2/      git tree, one commit per patch (base 699bc51d3)
rebase/build-series.sh       rebuilds the series in order, stops at the first failure
rebase/apply-series.sh       one-shot applicability probe
binbuild/bc-1.07.1/bc/bc     locally built bc (kernel needs it for timeconst.h)
```

## Why the quirks package is kernel-version-tied

`asus-proart-px13-quirks` is `arch=('any')` userspace config (UCM, PipeWire/WirePlumber
drop-ins, modprobe/udev rules). It carries no kernel code. Its `pkgver` is lockstep
bookkeeping; the dependency is a floor: `linux-cachyos-px13>=<pkgver>`.

The real lock is `linux-cachyos-px13`: it pins the CachyOS source tag
(`cachyos-<major>.<minor>-<tagrel>`) and applies in-tree patches in `prepare()` with
plain `patch -Np1`. A new kernel means re-basing that series.

## Series: 20 -> 19 patches

Dropped (already upstream in 7.2.9):

| old | what it did | upstream evidence |
|-----|-------------|-------------------|
| 0014-defer-check | ASoC `-EPROBE_DEFER` -> `unbind_card_list` | `snd_soc_bind_card()` now has the same block |
| 0015-to-help-alsa-find-them | `.component_name = "tas2783"` | present in `codec_info_list[]` |

Rebased by hand:

| patch | upstream change that broke it |
|-------|--------------------------------|
| 0003 | `tas_component_probe()`/`tas_component_remove()` rewritten; `tas25xx_register_misc()` gone. Now deletes the hooks and drops `.probe`/`.remove`. |
| 0006 | `sdca_parse_function()` is 3-arg (`dev, sdw, function`) and reads `function->desc`; SDCA headers moved `include/linux/soundwire/sdw_sdca.h` -> `include/sound/sdca{,.function}.h` |
| 0007 | same; AF01 fallback now builds a private `sdca_function_desc` (node/type/name) |
| 0009 | `soc_sdw_ti_amp.c` gained TAC5XX2 code, header gained declarations (context only) |
| 0016 | both codecs' `dev_resume()` now call `sdw_slave_wait_for_init()`; worker rewritten on top of it |

New:

* **0019-soundwire-amd-reattach-poll-after-resume.patch** — the post-s2idle audio fix, see below.

## The intermittent "no audio after standby" bug

Journal signature (16 resumes across recent boots: 4 bus failures, 12 codec init
timeouts, 5 firmware-download failures):

```
amd_sdw_manager amd_sdw_manager.1: No devices attached after resume timeout
rt721-sdca ...: Initialization not complete, timed out
slave-tas2783 ...: resume: initialization timed out
slave-tas2783 ...: error playback without fw download
snd_pci_ps ...: ACP: MSI unexpectedly enabled after resume ... disabling
```

Root cause, in `drivers/soundwire/amd_manager.c::amd_resume_runtime()`:

BIOS advertises `amd-sdw-power-mode = POWER_OFF`, so s2idle tears the whole bus down
(`sdw_clear_slave_status(bus, SDW_UNATTACH_REQUEST_MASTER_RESET)`). The resume path
then polled the ping status **5 times with 500-750 us sleeps (~3-4 ms total)**:

```c
if (amd_manager->status[0] == SDW_SLAVE_ATTACHED)
        schedule_work(&amd_manager->amd_sdw_work);
else
        dev_err(..., "No devices attached after resume timeout\n");
```

If the slaves are not ATTACHED inside that window it gives up permanently.
`amd_sdw_work` is what runs `sdw_handle_slave_status()`, which is what runs the codec
`update_status` callbacks, which is what re-downloads TAS2783 firmware via
`tas_io_init()`. Skipping it leaves the bus un-enumerated for the rest of the session:
codec workers time out, regmap stays cache-only, speakers stay dead until reboot.
Slaves that happen to answer inside 4 ms resume fine — hence "often works".

Fix: keep the short inline poll (fast path unchanged, and `amd_resume_runtime` is
inside the `dpm_resume` barrier so it must stay fast), and on failure continue polling
in process context from a new `resume_poll_work` for ~2.6 s, always handing over to
`amd_sdw_work` once the slaves answer. Worker is `cancel_work_sync()`'d in both
suspend paths and in `remove`, so it cannot race a following suspend.

This composes with 0016 (async codec resume): 0016 stops the desktop thaw from
blocking on the codec, 0019 makes the bus actually come back.

## Verification done

* `patch -Np1` cumulative apply on pristine `cachyos-7.2.9-2`: **19/19 OK, zero `.rej`, no fuzz**.
* Resulting tree byte-identical to the git-rebased tree (`diff -rq`).
* Targeted compile with `make LLVM=1` + CachyOS config + `-Werror`:
  `tas2783-sdw.o`, `rt721-sdca.o`, `rt721-sdca-sdw.o`, `soc_sdw_ti_amp.o`,
  `soc_sdw_utils.o`, `amd_manager.o`, `xhci-pci.o` all clean.
* `_patchsource` for `7.2` (`misc/dkms-clang.patch`) returns HTTP 200.
* `apply.sh`'s 3x `_pkgsuffix` guard passes on current upstream PKGBUILD.

## Not done

* Full kernel build: DONE (see "Build result" below).
* Install + reboot + real suspend/resume testing.

## Build result

Built with `makepkg --nodeps` (deps verified by hand; `bc` supplied from `~/binbuild`;
`CONFIG_RUST` drops out of the final `.config` by itself when rustc is absent, so the
rust packages were not needed). Thin LTO, 32 cores: ~17 min.

* `linux-cachyos-px13-7.2.9-1-x86_64.pkg.tar.zst`
* `linux-cachyos-px13-headers-7.2.9-1-x86_64.pkg.tar.zst`
* `asus-proart-px13-quirks-1:7.2.9-1-any.pkg.tar.zst`

Verified in the built modules: `soundwire-amd.ko` carries `Devices not detected after
resume, polling in background` and `Devices detected after resume, link %d`;
`snd-soc-tas2783-sdw.ko` carries the AF01 fallback, `Speaker Power`, `Channel
Playback`, `Amp Playback Volume`; `snd-soc-rt721-sdca.ko` carries the async-resume worker.

## Commands to run (need root)

```sh
cd ~/px13-work/linux-cachyos-px13   # packages are already built, see above

sudo pacman -U linux-cachyos-px13-7.2.9-1-x86_64.pkg.tar.zst \
               linux-cachyos-px13-headers-7.2.9-1-x86_64.pkg.tar.zst
# the limine-mkinitcpio-hook pacman hook builds the initramfs and the Limine entry,
# and the dkms hook rebuilds ryzen_smu-dkms-git against the new headers

cd ~/px13-work/asus-proart-px13-quirks
sudo pacman -U asus-proart-px13-quirks-1:7.2.9-1-any.pkg.tar.zst   # install kernel first
```

After reboot, watch for the fix:

```sh
journalctl -b -1.. -k | grep -E "resume timeout|polling in background|Devices detected after resume|initialization timed out|without fw download"
```

Expect `polling in background` followed by `Devices detected after resume, link N`
instead of `No devices attached after resume timeout`.

## Rollback-safe install (test kernel alongside the working one)

Installing `linux-cachyos-px13-7.2.9-1` **replaces** the installed `7.1.8-1`
(same package name), which removes the old kernel from `/boot` and
`/usr/lib/modules`. No fallback. So the 7.2.9 build is published under a
different package name instead:

```
linux-cachyos-px13-test            -> kernel 7.2.9-1-cachyos-px13-test
linux-cachyos-px13-test-headers
```

Only `_pkgsuffix` differs (`cachyos-px13-test`), which drives both `pkgbase`
and the kernel `localversion`, so the two kernels are fully independent:
separate `/usr/lib/modules/<uname>`, separate `/boot` files, separate
initramfs. `limine-mkinitcpio-install` loops over every installed kernel dir,
so the new one gets its own Limine menu entry and the 7.1.8 entry is left
alone. DKMS rebuilds `ryzen_smu-dkms-git` for both.

Install (keeps 7.1.8 fully intact):

```sh
cd ~/px13-work/linux-cachyos-px13-test
sudo pacman -U linux-cachyos-px13-test-7.2.9-1-x86_64.pkg.tar.zst \
               linux-cachyos-px13-test-headers-7.2.9-1-x86_64.pkg.tar.zst
```

Pick the new entry in the Limine menu. Nothing in the quirks package is
kernel-linked (UCM, PipeWire/WirePlumber drop-ins, modprobe.d, udev rules are
plain files), so it applies to the test kernel unchanged.

Rollback = pick the old entry at boot, and/or:

```sh
sudo pacman -Rns linux-cachyos-px13-test linux-cachyos-px13-test-headers
```

`asus-proart-px13-quirks` deliberately stays at `pkgver=7.1.8` during testing.
Its dep is `linux-cachyos-px13>=<pkgver>`; bumping it to 7.2.9 while only the
`-test` package provides 7.2.9 leaves an unmet dependency that pacman reports
on every `-Syu`.

### Promoting to the real package name (after testing)

```sh
cd ~/px13-work/linux-cachyos-px13
sed -i 's/^    _pkgsuffix=cachyos-px13-test$/    _pkgsuffix=cachyos-px13/' PKGBUILD   # already set
makepkg --nodeps -sf --noconfirm
sudo pacman -U linux-cachyos-px13-7.2.9-1-x86_64.pkg.tar.zst \
               linux-cachyos-px13-headers-7.2.9-1-x86_64.pkg.tar.zst
cd ~/px13-work/asus-proart-px13-quirks && sed -i 's/^pkgver=7.1.8$/pkgver=7.2.9/' PKGBUILD
makepkg --nodeps -f --noconfirm && sudo pacman -U asus-proart-px13-quirks-1:7.2.9-1-any.pkg.tar.zst
sudo pacman -Rns linux-cachyos-px13-test linux-cachyos-px13-test-headers   # optional cleanup
```

## Helper script

`~/px13-work/px13-kernel.sh` (run with sudo):

```sh
cd ~/px13-work
./px13-kernel.sh status     # installed kernels, boot entries, built packages
./px13-kernel.sh check      # verify packages contain the right uname + the resume fix (no root)
sudo ./px13-kernel.sh install   # install the -test kernel; 7.1.8 untouched
sudo ./px13-kernel.sh remove    # rollback: remove only the -test kernel
sudo ./px13-kernel.sh promote   # install as real linux-cachyos-px13 (REPLACES 7.1.8) + quirks bump
```

`install` verifies the package layout and that `soundwire-amd.ko` contains the
resume-poll fix *before* calling pacman, asks for confirmation, then reports the
module tree, the boot-partition files and the Limine entries. `promote` is the
only path that removes the 7.1.8 kernel and it is guarded by a confirmation.

Note: the script resolves its package directories from its own location
(`BASH_SOURCE`), not `$HOME` — under `sudo`, `HOME` is `/root`, so a `$HOME`-based
path looked in `/root/px13-work` and reported "not built". Override with
`PX13_WORK=/path/to/px13-work` if you move the script elsewhere.

## First boot on 7.2.9-1-cachyos-px13-test (2026-10-10)

Kernel side clean. One s2idle cycle (17:38:03 -> 17:38:18):

| boot | kernel | resumes | No devices attached | codec init timeouts | no-fw-download |
|------|--------|---------|---------------------|-------------------|----------------|
| -3 | 7.1.8-1-cachyos-px13 | 4 | 3 | 9 | 3 |
| -2 | 7.1.8-1-cachyos-px13 | 6 | 1 | 3 | 2 |
| 0  | 7.2.9-1-cachyos-px13-test | 1 | 0 | 0 | 0 |

- Direct ALSA playback after resume works: `aplay -D hw:1,2` -> `pcm2p/sub0` RUNNING,
  `hw_ptr` advancing at 48 kHz.
- Patch controls present: `tas2783-N Amp Playback Volume`, `tas2783-N Channel Playback`,
  `Speaker Switch` (DAPM switch from 0011).
- 0018 visible: `usb usb1: root hub lost power or was reset` + device re-enumeration.
- 0016 visible: thaw completes immediately, no blocking on codec resume.
- `Not enumerated, skip programming BUSCLOCK_SCALE` is **pre-existing** upstream
  (`drivers/soundwire/stream.c:702`, untouched by this series): 33 hits on boot -3,
  15 on boot -2, 3 on boot 0. Same for `ACP: MSI unexpectedly enabled after resume`.

At resume, `spa.alsa` logs `snd_pcm_avail after recover: Broken pipe` on
`hw:amdsoundwire,2p` and `4c`. This is PipeWire recovering from the XRUN that ALSA's
suspend path induces; it is a warning, and audio kept working. `wpctl` showing a port
in `[init]` and `/proc/asound/card1/pcm2p/sub0` as `closed` is just an idle sink with
no stream, not a failure. No userspace action is needed.

Patch 0019 follow-up: the background-poll message was `dev_dbg`, invisible in the
journal, so a slow-path resume looked identical to a fast-path one. Changed to
`dev_info` (commits `979d1ce` / `051a4fc`); series re-verified 19/19 clean. The
installed `-test` packages predate that change.
