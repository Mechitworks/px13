#!/usr/bin/env bash
#
# make-test-variant.sh — derive a parallel-install kernel package from linux-cachyos-px13
#
# Installing linux-cachyos-px13-<newver> REPLACES the installed package of the same
# name, which deletes the previous kernel from /boot and /usr/lib/modules. To validate
# a new kernel with a rollback path, build it under a different package name instead:
# _pkgsuffix drives both pkgbase and the kernel localversion, so the two kernels are
# fully independent (separate module tree, separate /boot files, separate initramfs,
# separate Limine entry).
#
#   ./make-test-variant.sh            -> ../linux-cachyos-px13-test
#   ./make-test-variant.sh myname     -> ../linux-cachyos-px13-myname
#
# Only _pkgsuffix changes. The quirks package deliberately keeps its pkgver at the
# INSTALLED kernel version: its dependency is linux-cachyos-px13>=<pkgver> and a
# -test package cannot satisfy it, which pacman reports as an unmet dep on every -Syu.

set -euo pipefail

SUFFIX="${1:-test}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg="linux-cachyos-px13"
dst="${root}/../${pkg}-${SUFFIX}"

[[ -d "${root}/.git" ]] || { echo "error: ${root} is not a git repository" >&2; exit 1; }
[[ -e "$dst" ]] && { echo "error: $dst already exists" >&2; exit 1; }

mkdir -p "$dst"
# tracked files only: PKGBUILD, config, apply.sh, patches, .SRCINFO, .gitignore
git -C "$root" archive HEAD "$pkg" | tar x --strip-components=1 -C "$dst"

# upstream PKGBUILD sets _pkgsuffix in three places (channel detection); all three
# must be rewritten, which is exactly what apply.sh guards for.
n=$(grep -c '^    _pkgsuffix=cachyos-px13$' "$dst/PKGBUILD")
[[ "$n" -eq 3 ]] || { echo "error: expected 3 _pkgsuffix lines, found $n (upstream changed shape)" >&2; exit 1; }
sed -i "s/^    _pkgsuffix=cachyos-px13\$/    _pkgsuffix=cachyos-px13-${SUFFIX}/" "$dst/PKGBUILD"

( cd "$dst" && makepkg --printsrcinfo > .SRCINFO )

echo "created: $dst"
grep -E "^pkgbase =|^pkgname =" "$dst/.SRCINFO" | sed 's/^/  /'
echo "  kernel uname base: $(grep -m1 '^_kernuname=' "$dst/PKGBUILD" | sed 's/.*=//') (pkgrel appended at build)"
