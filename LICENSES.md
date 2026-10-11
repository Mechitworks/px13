# Licenses

This repository mixes two packages with different licenses, so there is no single
top-level `LICENSE` file. Each directory carries its own terms, matching the
`license=()` array in its PKGBUILD:

| path | license | why |
|------|---------|-----|
| `linux-cachyos-px13/` | GPL-2.0-only | derivative work of the Linux kernel; inherits the kernel's license. The 19 patches in this directory are GPL-2.0-only. |
| `asus-proart-px13-quirks/` | CC0-1.0 | userspace configuration only (ALSA UCM files, PipeWire/WirePlumber drop-ins, modprobe.d and udev rules) |
| `px13-kernel.sh`, `make-test-variant.sh` | CC0-1.0 | packaging/helper scripts, not kernel code |
| `README.md` | CC0-1.0 | documentation |

The upstream CachyOS `PKGBUILD` and `config` inherited by `linux-cachyos-px13/` are
upstream's work; the fork's additions are the patch files and the customization block
appended at the end of the PKGBUILD.

Full license texts: <https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt> and
<https://creativecommons.org/publicdomain/zero/1.0/legalcode>.
