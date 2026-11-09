#!/bin/bash
# Time an unattended XCP-ng install of <iso> in QEMU/KVM (UEFI, OVMF), from QEMU
# start to the reboot that ends the install. Results land in <run-dir>.
#
# Usage: run-bench.sh <iso> <run-dir> [<overlay-dir>...]
#   overlay dirs are appended to install.img (e.g. a patched /opt/xensource/installer)
# Env: BENCH_CPUS (4), BENCH_MEM (8192), BENCH_TIMEOUT (3600),
#      OVMF_CODE / OVMF_VARS (Fedora paths by default)
set -euo pipefail
export LC_ALL=C
[ $# -ge 2 ] || { sed -n 2,9p "$0"; exit 1; }
ISO=$(realpath "$1"); W=$(realpath -m "$2"); shift 2
HERE=$(dirname "$(realpath "$0")")
OVMF_CODE=${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/edk2/ovmf/OVMF_VARS.fd}
for t in qemu-system-x86_64 7z mkfs.vfat mmd mcopy cpio; do command -v $t >/dev/null || { echo "missing $t" >&2; exit 1; }; done
mkdir -p "$W/boot"

# Boot files straight from the ISO; GRUB entry with the answerfile on the command line
for f in EFI/xenserver/grubx64.efi boot/xen.gz boot/vmlinuz install.img; do
    7z e -so "$ISO" "$f" > "$W/boot/$(basename $f)"
done
rm -rf "$W/ov"; mkdir -p "$W/ov"; cp -a "$HERE/overlay/." "$W/ov/"; cp "$HERE/answerfile.xml" "$W/ov/"
for ov in "$@"; do cp -a "$ov/." "$W/ov/"; done
find "$W/ov" -name __pycache__ -prune -exec rm -rf {} +
# initrd = install.img + 4-byte aligned uncompressed cpio overlay (kernel ignores it otherwise)
cp "$W/boot/install.img" "$W/initrd.img"; truncate -s %512 "$W/initrd.img"
( cd "$W/ov" && find . | cpio -o -H newc -R 0:0 --quiet ) >> "$W/initrd.img"
cat > "$W/grub.cfg" <<GRUB
set timeout=0
insmod gzio
menuentry "bench" {
    multiboot2 /boot/xen.gz dom0_max_vcpus=1-16 dom0_mem=max:8192M com1=115200,8n1 console=com1
    module2 /boot/vmlinuz no-repo-gpgcheck console=hvc0 selinux=0 answerfile=file:///answerfile.xml install
    module2 /boot/initrd.img
}
GRUB
# ESP on an AHCI disk (USB storage is far too slow for a 200MB initrd under OVMF)
rm -f "$W/esp.img"; truncate -s 400M "$W/esp.img"; mkfs.vfat -F32 "$W/esp.img" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$W/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/xenserver ::/boot
mcopy -i "$W/esp.img" "$W/boot/grubx64.efi" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$W/esp.img" "$W/grub.cfg" ::/EFI/xenserver/grub.cfg
mcopy -i "$W/esp.img" "$W/boot/xen.gz" "$W/boot/vmlinuz" "$W/initrd.img" ::/boot/
# The installer requires >= 46GB; sparse file
rm -f "$W/disk.img"; truncate -s 64G "$W/disk.img"
cp "$OVMF_VARS" "$W/vars.fd"
START=$(date +%s.%N)
timeout ${BENCH_TIMEOUT:-3600} qemu-system-x86_64 -machine q35,accel=kvm -cpu host \
  -smp ${BENCH_CPUS:-4} -m ${BENCH_MEM:-8192} \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$W/vars.fd" \
  -drive file="$W/esp.img",format=raw,if=none,id=esp -device ide-hd,drive=esp,bus=ide.1,bootindex=0 \
  -drive file="$W/disk.img",format=raw,if=virtio,cache=none,aio=native \
  -drive file="$ISO",format=raw,if=none,id=cd,media=cdrom,readonly=on -device ide-cd,drive=cd,bus=ide.2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
  -display none -monitor unix:"$W/mon.sock",server,nowait -serial file:"$W/serial.raw" -no-reboot || true
END=$(date +%s.%N)
rm -f "$W/esp.img" "$W/initrd.img"
awk -v s=$START -v e=$END 'BEGIN { printf "TOTAL %.1fs\n", e - s }' | tee "$W/total"
