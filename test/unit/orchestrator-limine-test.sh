#!/usr/bin/env bash
# limine.sh: the limine-entry-tool config parsers, the efibootmgr snapshot
# handling, /etc/default/limine generation and the EFI file install — all
# against temp files and recording fakes.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

section 'strip_shell_quotes'
check 'double quotes' eq "$(strip_shell_quotes '"/boot"')" /boot
check 'single quotes' eq "$(strip_shell_quotes "'x y'")" 'x y'
check 'whitespace' eq "$(strip_shell_quotes '  "v"  ')" v
check 'mismatched left alone' eq "$(strip_shell_quotes '"v')" '"v'
check 'one char' eq "$(strip_shell_quotes '"')" '"'

section 'limine_setting'
cfg=$'ESP_PATH="/boot"\n  CUSTOM_UKI_NAME = omarchy  \nESP_PATH=/efi\n# ESP_PATH=/nope'
check 'last assignment wins, quotes stripped' eq "$(limine_setting "$cfg" ESP_PATH /x)" /efi
check 'spaces around =' eq "$(limine_setting "$cfg" CUSTOM_UKI_NAME)" omarchy
check 'fallback' eq "$(limine_setting "$cfg" MISSING dflt)" dflt
check 'comments ignored' eq "$(limine_setting $'# ESP_PATH=/nope' ESP_PATH /d)" /d

section 'limine_kernel_cmdline'
cfg=$'KERNEL_CMDLINE[default]+=" root=UUID=1 rw "\nKERNEL_CMDLINE[default]+=""\n  KERNEL_CMDLINE[default]+=\'quiet splash\'\nKERNEL_CMDLINE[other]+="x"'
check 'joined, trimmed, empties skipped, other keys ignored' eq "$(limine_kernel_cmdline "$cfg")" 'root=UUID=1 rw quiet splash'
check 'none' eq "$(limine_kernel_cmdline 'ESP_PATH=/boot')" ''

section 'limine_combined_config_text'
fresh_target
mkdir -p "$CTX_TARGET/usr/share/limine-entry-tool.d" "$CTX_TARGET/etc/limine-entry-tool.d"
printf 'A=1\n' >"$CTX_TARGET/usr/share/limine-entry-tool.d/10-a.conf"
printf 'A=2\n' >"$CTX_TARGET/etc/limine-entry-tool.conf"
printf 'A=3\n' >"$CTX_TARGET/etc/limine-entry-tool.d/50-b.conf"
check 'vendor < legacy < etc.d < default' eq "$(limine_combined_config_text 'A=4' | grep -o 'A=.' | tr '\n' ' ')" 'A=1 A=2 A=3 A=4 '
check 'default wins' eq "$(limine_setting "$(limine_combined_config_text 'A=4')" A)" 4

section 'efibootmgr snapshot'
efibootmgr() {
  record "efibootmgr $*"
  (($# == 0)) || return 0
  cat <<'OUT'
BootCurrent: 0003
Timeout: 1 seconds
BootOrder: 0003,0001,0002
Boot0001* Windows Boot Manager	HD(1,GPT,...)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0002  UEFI Shell	FvVol(...)
Boot0003* Limine	HD(1,GPT,...)/File(\EFI\limine\limine_x64.efi)
Boot000a* limine (old)	HD(...)
OUT
}
snap=$(read_efibootmgr)
# Like the Python regex it replaces, the label field keeps the tab-separated
# device path efibootmgr prints after the name; matching is by substring.
check 'entries (label field) and order' eq "$(awk -F'\t' '{ print $1 "=" $2 }' <<<"$snap" | tr '\n' ' ')" '0001=Windows Boot Manager 0002=UEFI Shell 0003=Limine 000A=limine (old) ORDER=0003,0001,0002 '
check 'find by label, case-insensitive' eq "$(find_label_entries "$snap" limine | tr '\n' ' ')" '0003 000A '
check 'find windows' eq "$(find_label_entries "$snap" Windows)" 0001
check 'order' eq "$(efibootmgr_order "$snap")" '0003,0001,0002'
check 'has entry' test "$(efibootmgr_has_entry "$snap" 0002; echo $?)/$(efibootmgr_has_entry "$snap" 0009; echo $?)" == 0/1

section 'register_limine_efi_entry'
reset_calls
# after --create, the new entry shows up as 0004
efibootmgr() {
  record "efibootmgr $*"
  (($# == 0)) || return 0
  printf 'BootOrder: 0003,0001,0002,000A\nBoot0001* Windows Boot Manager\nBoot0002  UEFI Shell\nBoot0004* Limine\n'
}
pre=$'0001\tWindows Boot Manager\n0002\tUEFI Shell\n0003\tLimine\n000A\tlimine (old)\nORDER\t0003,0001,0002,000A'
run_phase register_limine_efi_entry /dev/vda 1 '\EFI\limine\limine_x64.efi' "$pre"
check 'phase ok' eq "$?" 0
check 'stale limine entries deleted' eq "$(calls | grep -c -- '--delete-bootnum')" 2
check 'stale 0003 deleted' contains "$(calls)" 'efibootmgr --bootnum 0003 --delete-bootnum'
check 'created' contains "$(calls)" 'efibootmgr --create --disk /dev/vda --part 1 --label Limine --loader \EFI\limine\limine_x64.efi --unicode --verbose'
check 'new entry first, stale dropped, unknown dropped, others kept' contains "$(calls)" 'efibootmgr --bootorder 0004,0001,0002'

section 'split_partition_device'
lsblk() { case $2 in PKNAME) echo nvme0n1 ;; PARTN) echo 3 ;; esac; }
check 'disk and number' eq "$(split_partition_device /dev/nvme0n1p3)" '/dev/nvme0n1 3'

section 'write_limine_defaults'
fresh_target
mkdir -p "$CTX_TARGET/usr/share/omarchy/install/assets/limine"
printf 'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="@@CMDLINE@@"\n' >"$CTX_TARGET/usr/share/omarchy/install/assets/limine/default.conf"
printf 'timeout: 3\n' >"$CTX_TARGET/usr/share/omarchy/install/assets/limine/limine.conf"
arch_has_uefi() { return 0; }
run_phase write_limine_defaults 'root=UUID=1 rw rootfstype=btrfs' /efi
check 'phase ok' eq "$?" 0
d=$(cat "$CTX_TARGET/etc/default/limine")
check 'cmdline substituted' contains "$d" 'KERNEL_CMDLINE[default]+="root=UUID=1 rw rootfstype=btrfs"'
check 'ESP_PATH rewritten' contains "$d" 'ESP_PATH="/efi"'
check 'no fallback line unless asked' test -z "$(grep ENABLE_LIMINE_FALLBACK <<<"$d" || true)"
check 'kernel cmdline file' eq "$(cat "$CTX_TARGET/etc/kernel/cmdline")" 'root=UUID=1 rw rootfstype=btrfs'
check 'limine.conf template copied to the ESP' eq "$(cat "$CTX_TARGET/efi/limine.conf")" 'timeout: 3'
run_phase write_limine_defaults 'root=UUID=1 rw' /boot false
check 'fallback=false line' contains "$(cat "$CTX_TARGET/etc/default/limine")" 'ENABLE_LIMINE_FALLBACK=no'
arch_has_uefi() { return 1; }
run_phase write_limine_defaults 'root=UUID=1 rw' /boot
check 'BIOS: UKI and fallback off' contains "$(cat "$CTX_TARGET/etc/default/limine")" $'ENABLE_UKI=no\nENABLE_LIMINE_FALLBACK=no'
run_phase write_limine_defaults 'rw' /boot
check 'cmdline without root= refused' contains "$(cat "$ERR")" 'has no root='
arch_has_uefi() { return 0; }

section 'install_limine_efi'
fresh_target
mkdir -p "$CTX_TARGET/usr/share/limine"; printf 'efi' >"$CTX_TARGET/usr/share/limine/BOOTX64.EFI"
register_limine_efi_entry() { record "register $*"; }
run_phase install_limine_efi /boot /dev/vda 1 false
check 'phase ok' eq "$?" 0
check 'binary copied to ESP' eq "$(cat "$CTX_TARGET/boot/EFI/limine/limine_x64.efi")" efi
check 'pacman hook' contains "$(cat "$CTX_TARGET/etc/pacman.d/hooks/99-omarchy-limine.hook")" 'Exec = /bin/sh -c "/usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi"'
check 'EFI loader path' contains "$(calls)" 'register /dev/vda 1 \EFI\limine\limine_x64.efi'
fresh_target; mkdir -p "$CTX_TARGET/usr/share/limine"; printf 'efi' >"$CTX_TARGET/usr/share/limine/BOOTX64.EFI"
run_phase install_limine_efi /boot /dev/vda 1 true
check 'removable: fallback path' test -f "$CTX_TARGET/boot/EFI/BOOT/BOOTX64.EFI"
check 'removable: loader' contains "$(calls)" 'register /dev/vda 1 \EFI\BOOT\BOOTX64.EFI'
fresh_target
run_phase install_limine_efi /boot /dev/vda 1 false
check 'missing limine package fails clearly' contains "$(cat "$ERR")" 'Required Limine file missing'

finish
