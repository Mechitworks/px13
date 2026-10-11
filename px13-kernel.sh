#!/usr/bin/env bash
#
# px13-kernel.sh — manage the rebased PX13 kernel (cachyos-7.2.9-2 + 19 patches)
#
# Run with sudo:   sudo ./px13-kernel.sh [command]
#
#   status   (default)  show installed kernels, boot entries, build artifacts
#   check               verify the built packages contain the right kernel and
#                       the post-s2idle resume fix (no root needed)
#   install             install the PARALLEL TEST kernel (linux-cachyos-px13-test)
#                       -> your working 7.1.8 kernel is left completely untouched
#   remove              remove the test kernel (rollback)
#   promote             install as the real linux-cachyos-px13 (REPLACES 7.1.8)
#                       and bump asus-proart-px13-quirks to lockstep
#
# Nothing here ever deletes the currently installed kernel except `promote`,
# which is guarded by an explicit confirmation.

set -euo pipefail

# Resolve paths from the script's own location, NOT $HOME: under `sudo` HOME is
# /root, which made every package lookup fail with "not built".
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd -P)"
WORK="${PX13_WORK:-$SCRIPT_DIR}"
TEST_DIR="${WORK}/linux-cachyos-px13-test"
REL_DIR="${WORK}/linux-cachyos-px13"
QUIRKS_DIR="${WORK}/asus-proart-px13-quirks"

TEST_PKGVER="7.2.9-1"
TEST_PKG="linux-cachyos-px13-test"
REL_PKG="linux-cachyos-px13"
TEST_UNAME="7.2.9-1-cachyos-px13-test"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_bld=$'\e[1m'; c_off=$'\e[0m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$c_bld" "$c_off" "$*"; }
ok()   { printf '%sok%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%serror%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# absolute paths, resolved from the script location (see above)
for _d in "$TEST_DIR" "$REL_DIR" "$QUIRKS_DIR"; do
    [[ -d "$_d" ]] || die "missing directory: ${_d} (override with PX13_WORK=/path)"
done

need_root() {
    [[ ${EUID} -eq 0 ]] || die "run me with sudo:  sudo $0 ${CMD:-install}"
}

# ---------------------------------------------------------------- artifacts --

pkg_path() {   # pkg_path <dir> <name>
    local dir="$1" name="$2" f
    f="$(find "$dir" -maxdepth 1 -name "${name}-${TEST_PKGVER}-*.pkg.tar.zst" -print -quit 2>/dev/null || true)"
    [[ -n "$f" && -s "$f" ]] || die "not built: ${name} (expected in ${dir})"
    printf '%s\n' "$f"
}

verify_pkg() {   # verify_pkg <file> <expected uname>
    local f="$1" uname="$2" list
    list="$(tar --zstd -tf "$f" 2>/dev/null)"    # capture: grep -q would SIGPIPE tar under pipefail
    grep -q "usr/lib/modules/${uname}/vmlinuz" <<<"$list" \
        || die "${f##*/} does not contain usr/lib/modules/${uname}/vmlinuz"
    ok "kernel package ok: ${uname}"
}

verify_headers() {   # verify_headers <file> <expected uname>
    local f="$1" uname="$2" list
    list="$(tar --zstd -tf "$f" 2>/dev/null)"
    grep -q "usr/lib/modules/${uname}/build/" <<<"$list" \
        || die "${f##*/} does not contain usr/lib/modules/${uname}/build (DKMS needs it)"
    ok "headers package ok: ${uname}"
}

verify_fix() {   # verify_fix <file> <uname>  -- the post-s2idle audio fix
    local f="$1" uname="$2" mod
    mod="usr/lib/modules/${uname}/kernel/drivers/soundwire/soundwire-amd.ko.zst"
    local hits
    hits="$(tar --zstd -xOf "$f" "$mod" 2>/dev/null | zstd -dc 2>/dev/null \
            | strings | grep -cE 'polling in background|Devices detected after resume, link' || true)"
    [[ "${hits:-0}" -ge 2 ]] || die "resume-poll fix not found in soundwire-amd.ko inside ${f##*/}"
    ok "resume-poll fix present in soundwire-amd.ko"
}

# ------------------------------------------------------------------- status --

show_kernels() {
    info "installed kernel packages"
    pacman -Qs '^linux-cachyos' 2>/dev/null | grep -E '^local/' | sed 's/^/  /' || say "  (none)"
    say ""
    info "installed kernel trees"
    local d n
    for d in /usr/lib/modules/*/; do
        [[ -e "${d}/vmlinuz" ]] || continue
        n="${d%/}"; n="${n##*/modules/}"
        printf '  %-32s %s\n' "$n" "$(stat -c %y "${d}/vmlinuz" | cut -d' ' -f1)"
    done
}

show_entries() {
    command -v limine-list >/dev/null 2>&1 || { warn "limine-list not found, skipping boot entries"; return 0; }
    info "boot entries (limine)"
    limine-list 2>/dev/null | sed 's/^/  /' \
        || warn "limine-list failed (reading the boot partition needs root)"
}

show_artifacts() {
    info "built packages"
    local f
    for f in "${TEST_DIR}/${TEST_PKG}-${TEST_PKGVER}"-x86_64.pkg.tar.zst \
             "${TEST_DIR}/${TEST_PKG}-headers-${TEST_PKGVER}"-x86_64.pkg.tar.zst \
             "${REL_DIR}/${REL_PKG}-${TEST_PKGVER}"-x86_64.pkg.tar.zst \
             "${REL_DIR}/${REL_PKG}-headers-${TEST_PKGVER}"-x86_64.pkg.tar.zst; do
        if [[ -s "$f" ]]; then
            printf '  %s  %8d KB  %s\n' "$c_grn* $c_off" "$(( $(stat -c %s "$f") / 1024 ))" "${f##*/}"
        else
            printf '  %s- %s %s\n' "$c_yel" "${f##*/}" "(not built)" "$c_off"
        fi
    done
}

cmd_status() {
    show_kernels; say ""
    show_artifacts; say ""
    show_entries
}

# ------------------------------------------------------------------ install --

confirm() {   # confirm <prompt>
    local reply
    printf '%s\n' "$1"
    [[ -t 0 ]] || { warn "stdin not a tty, refusing to guess"; return 1; }
    read -r -p "  proceed? [y/N] " reply
    [[ "${reply}" == y || "${reply}" == Y ]]
}

run_install() {   # run_install <pkgfile...>
    local -a files=("$@")
    info "pacman -U ${files[*]/#/.../}"
    # --needed: don't reinstall; hooks in limine-mkinitcpio-hook + dkms run PostTransaction
    pacman -U --needed "${files[@]}"
}

after_install_checks() {   # after_install_checks <uname>
    local uname="$1"
    say ""
    info "post-install verification: ${uname}"
    local esp="" p
    for p in /boot /efi /boot/efi /limine; do
        [[ -f "${p}/limine.conf" || -d "${p}/EFI/limine" ]] && { esp="$p"; break; }
    done
    [[ -e "/usr/lib/modules/${uname}/vmlinuz" ]] \
        && ok "module tree: /usr/lib/modules/${uname}" \
        || warn "module tree missing: /usr/lib/modules/${uname}"

    local found_initrd=0
    if [[ -n "$esp" ]]; then
        mapfile -t < <(find "${esp}" -maxdepth 3 \( -name "*${uname}*" \) -print 2>/dev/null) || true
        if ((${#found_initrd[@]})); then
            for p in "${found_initrd[@]}"; do printf '  %s\n' "$p"; done
            found_initrd=1
        fi
    fi
    ((found_initrd)) \
        && ok "kernel/initramfs files present on the boot partition" \
        || warn "no ${uname} files found on the boot partition (initramfs may have failed)"

    command -v limine-list >/dev/null 2>&1 && { say ""; show_entries; }
}

cmd_install() {
    need_root
    say "${c_bld}Install the PARALLEL TEST kernel ${TEST_PKG} ${TEST_PKGVER}${c_off}"
    say "  kernel uname : ${TEST_UNAME}"
    say "  your existing ${REL_PKG} kernel is NOT touched; it keeps its boot entry"
    say ""
    show_kernels; say ""

    local k h
    k="$(pkg_path "$TEST_DIR" "$TEST_PKG")"
    h="$(pkg_path "$TEST_DIR" "${TEST_PKG}-headers")"
    verify_pkg "$k" "$TEST_UNAME"
    verify_fix "$k" "$TEST_UNAME"
    verify_headers "$h" "$TEST_UNAME"
    say ""

    confirm "" || { say "aborted."; exit 1; }
    run_install "$k" "$h"
    after_install_checks "$TEST_UNAME"

    say ""
    info "next steps"
    say "  1. reboot and pick the ${c_bld}${TEST_UNAME}${c_off} entry in the Limine menu"
    say "  2. suspend/resume a few times, then check:"
    say "       journalctl -b -k | grep -E 'polling in background|Devices detected after resume|resume timeout|initialization timed out|without fw download'"
    say "     you want 'polling in background' -> 'Devices detected after resume, link N'"
    say "     instead of 'No devices attached after resume timeout'"
    say ""
    info "rollback (safe, removes only the test kernel)"
    say "  sudo $0 remove"
}

cmd_remove() {
    need_root
    if ! pacman -Qq "$TEST_PKG" >/dev/null 2>&1; then
        warn "${TEST_PKG} is not installed; nothing to do"; return 0
    fi
    say "${c_bld}Remove the test kernel ${TEST_PKG}${c_off}"
    say "  the real ${REL_PKG} kernel is not touched"
    say ""
    confirm "" || { say "aborted."; exit 1; }
    pacman -Rns "$TEST_PKG" "${TEST_PKG}-headers"
    say ""
    show_kernels
}

# ------------------------------------------------------------------ promote --

cmd_promote() {
    need_root
    say "${c_bld}PROMOTE: install as the real ${REL_PKG} package${c_off}"
    say "  ${c_red}this REPLACES ${REL_PKG} 7.1.8-1 and removes that kernel from /boot${c_off}"
    say "  after this there is no 7.1.8 fallback entry"
    say ""
    show_kernels; say ""

    local k h
    k="$(pkg_path "$REL_DIR" "$REL_PKG")"
    h="$(pkg_path "$REL_DIR" "${REL_PKG}-headers")"
    verify_pkg "$k" "7.2.9-1-cachyos-px13"
    verify_fix "$k" "7.2.9-1-cachyos-px13"
    verify_headers "$h" "7.2.9-1-cachyos-px13"
    say ""

    confirm "" || { say "aborted."; exit 1; }
    run_install "$k" "$h"
    after_install_checks "7.2.9-1-cachyos-px13"

    # quirks lockstep bump + rebuild, done as the invoking user (makepkg as root is a bad idea)
    local runuser="${SUDO_USER:-}"
    if [[ -n "$runuser" && -d "$QUIRKS_DIR" ]]; then
        say ""
        info "bumping asus-proart-px13-quirks to lockstep 7.2.9 (as user ${runuser})"
        sudo -u "$runuser" bash -c "cd '$QUIRKS_DIR' \
            && sed -i 's/^pkgver=7.1.8\$/pkgver=7.2.9/' PKGBUILD \
            && makepkg --nodeps -f --noconfirm" \
            || warn "quirks rebuild failed; do it manually in ${QUIRKS_DIR}"
        local q
        q="$(find "$QUIRKS_DIR" -maxdepth 1 -name 'asus-proart-px13-quirks-1:7.2.9-1-any.pkg.tar.zst' -print -quit 2>/dev/null || true)"
        if [[ -n "$q" ]]; then
            pacman -U --needed "$q"
            ok "quirks installed at 1:7.2.9 (dep linux-cachyos-px13>=7.2.9 now satisfiable)"
        else
            warn "quirks package not found; its dep linux-cachyos-px13>=7.2.9 will show as unmet"
        fi
    else
        warn "SUDO_USER unset or ${QUIRKS_DIR} missing; bump asus-proart-px13-quirks pkgver to 7.2.9 manually"
    fi

    say ""
    info "optional cleanup of the test kernel"
    say "  sudo $0 remove"
}

cmd_check() {
    say "${c_bld}Verifying built artifacts (no root needed)${c_off}"
    say ""
    local k h
    k="$(pkg_path "$TEST_DIR" "$TEST_PKG")"
    h="$(pkg_path "$TEST_DIR" "${TEST_PKG}-headers")"
    verify_pkg "$k" "$TEST_UNAME"
    verify_fix "$k" "$TEST_UNAME"
    verify_headers "$h" "$TEST_UNAME"
    say ""
    k="$(pkg_path "$REL_DIR" "$REL_PKG")"
    h="$(pkg_path "$REL_DIR" "${REL_PKG}-headers")"
    verify_pkg "$k" "7.2.9-1-cachyos-px13"
    verify_fix "$k" "7.2.9-1-cachyos-px13"
    verify_headers "$h" "7.2.9-1-cachyos-px13"
    say ""
    ok "all four packages verified"
}

# --------------------------------------------------------------------- main --

CMD="${1:-status}"
case "$CMD" in
    status)  cmd_status ;;
    check)   cmd_check ;;
    install) cmd_install ;;
    remove)  cmd_remove ;;
    promote) cmd_promote ;;
    -h|--help|help) sed -n '3,17p' "$0" | sed 's/^# {0,1}//' ;;
    *) die "unknown command: ${CMD} (status|check|install|remove|promote)" ;;
esac
