#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
conf="$ROOT/source/amneziawg/dkms.conf"

fail() {
  echo "error: $*" >&2
  exit 1
}

[ -f "$conf" ] || fail "missing $conf"
grep -q '^PACKAGE_NAME="amneziawg"$' "$conf" || fail "PACKAGE_NAME must be amneziawg"
grep -q '^AUTOINSTALL="no"$' "$conf" || fail "AUTOINSTALL must be no (chroot/host uname -r is not the Y700 ABI)"
grep -q 'REMAKE_INITRD' "$conf" && fail "dkms.conf must not set REMAKE_INITRD"
grep -q 'DEST_MODULE_LOCATION\[0\]="/updates"' "$conf" || fail "module must install into /updates on rootfs"
grep -q 'BUILD_EXCLUSIVE_KERNEL="^__KERNEL_ABI_RELEASE__$"' "$conf" || fail "BUILD_EXCLUSIVE_KERNEL must pin the ABI placeholder"
grep -q 'KERNELDIR=/lib/modules/\${kernelver}/build' "$conf" || fail "MAKE must use /lib/modules headers"

skip="$ROOT/source/y700-dkms-rootfs-only/usr/lib/y700-dkms/skip-boot-tool"
protect="$ROOT/source/y700-dkms-rootfs-only/usr/lib/y700-dkms/protect-boot-tools.sh"
install="$ROOT/source/y700-dkms-rootfs-only/usr/lib/y700-dkms/install-pinned-module.sh"
[ -x "$skip" ] || fail "skip-boot-tool must be executable"
[ -x "$protect" ] || fail "protect-boot-tools.sh must be executable"
[ -x "$install" ] || fail "install-pinned-module.sh must be executable"
grep -q 'update-initramfs' "$protect" || fail "protect-boot-tools.sh must divert update-initramfs"
grep -q 'grub-install' "$protect" || fail "protect-boot-tools.sh must divert grub-install"
grep -q 'install -d' "$protect" || fail "protect-boot-tools.sh must create missing boot-hook directories"
grep -q 'refusing boot/grub update' "$skip" || fail "skip-boot-tool must refuse boot/grub updates"
grep -q 'cmp -s' "$install" || fail "install-pinned-module.sh must compare /boot before and after DKMS"

echo "ok: AmneziaWG DKMS rootfs-only policy"
