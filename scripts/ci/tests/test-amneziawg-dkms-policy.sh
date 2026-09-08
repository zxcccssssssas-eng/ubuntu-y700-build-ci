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
grep -q '^PACKAGE_NAME=amneziawg-dkms$' "$protect" || fail "boot-tool diverts must be owned by amneziawg-dkms"
grep -q 'update-initramfs' "$protect" || fail "protect-boot-tools.sh must divert update-initramfs"
grep -q 'grub-install' "$protect" || fail "protect-boot-tools.sh must divert grub-install"
grep -q 'install -d' "$protect" || fail "protect-boot-tools.sh must create missing boot-hook directories"
grep -q 'refusing boot/grub update' "$skip" || fail "skip-boot-tool must refuse boot/grub updates"
grep -q 'cmp -s' "$install" || fail "install-pinned-module.sh must compare /boot before and after DKMS"

builder="$ROOT/scripts/ci/build-amneziawg-debs.sh"
[ -f "$builder" ] || fail "missing $builder"
grep -q 'Package: amneziawg-dkms' "$builder" || fail "builder must produce amneziawg-dkms"
grep -q 'Package: y700-dkms-rootfs-only' "$builder" && fail "builder must not emit a separate y700-dkms-rootfs-only deb"
grep -q 'Package: amneziawg-tools' "$builder" && fail "builder must not emit a separate amneziawg-tools deb"
grep -q 'combined_deb=yes' "$builder" || fail "builder must record a combined deb"
grep -q 'touches_boot=no' "$builder" || fail "builder must record that boot is not touched"
grep -q 'expected a single amneziawg-dkms deb' "$builder" || fail "builder must fail if more than one deb is produced"

postinst_hint=$(awk '/DEBIAN\/postinst/, /^POST$/' "$builder")
[ -n "$postinst_hint" ] || fail "could not locate combined package postinst in builder"
printf '%s\n' "$postinst_hint" | grep -q 'update-initramfs' && fail "combined postinst must not run update-initramfs"
printf '%s\n' "$postinst_hint" | grep -q 'update-grub' && fail "combined postinst must not run update-grub"
printf '%s\n' "$postinst_hint" | grep -q 'grub-install' && fail "combined postinst must not run grub-install"
printf '%s\n' "$postinst_hint" | grep -q 'dkms install' && fail "combined postinst must not compile against the host kernel"

echo "ok: AmneziaWG DKMS rootfs-only policy"
