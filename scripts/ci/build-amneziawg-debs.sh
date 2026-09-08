#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build a single amneziawg-dkms .deb: DKMS source, a prebuilt amneziawg.ko for
the pinned Y700 ABI, awg/awg-quick, and rootfs-only boot/grub guards. The
module is installed only under /lib/modules/<abi>/updates. The package never
runs update-initramfs, grub-install, or other boot-partition writers.

Kernel headers stay in y700-daily-kernel-headers (built separately).

Environment inputs:
  OUTPUT_DIR                 default: out/amneziawg-debs
  KERNEL_MODULES_DEB_DIR     directory containing y700-daily-kernel-headers_*.deb
  KERNEL_HEADERS_DEB         optional explicit headers deb path
  KERNEL_ABI_RELEASE         default: 7.1.1-g5df8e852ea72
  AMNEZIAWG_MODULE_REPO      default: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
  AMNEZIAWG_MODULE_REF       git commit, default: 4569c4c67f3a57414969260cafbbd04694fbaae0
  AMNEZIAWG_TOOLS_REPO       default: https://github.com/amnezia-vpn/amneziawg-tools
  AMNEZIAWG_TOOLS_REF        git commit, default: ee0f0a9aa34ff0a0da4b3433b9512781cfe02843
  AMNEZIAWG_DKMS_VERSION     Debian version, default: 1.0.0+y700.2
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd git
ci_require_cmd make
ci_require_cmd gcc
ci_require_cmd dpkg-deb
ci_require_cmd rsync
ci_require_cmd sha256sum
ci_require_cmd tar
ci_require_cmd modinfo

OUTPUT_DIR=${OUTPUT_DIR:-out/amneziawg-debs}
KERNEL_MODULES_DEB_DIR=${KERNEL_MODULES_DEB_DIR:-}
KERNEL_HEADERS_DEB=${KERNEL_HEADERS_DEB:-}
KERNEL_ABI_RELEASE=${KERNEL_ABI_RELEASE:-7.1.1-g5df8e852ea72}
AMNEZIAWG_MODULE_REPO=${AMNEZIAWG_MODULE_REPO:-https://github.com/amnezia-vpn/amneziawg-linux-kernel-module}
AMNEZIAWG_MODULE_REF=${AMNEZIAWG_MODULE_REF:-4569c4c67f3a57414969260cafbbd04694fbaae0}
AMNEZIAWG_TOOLS_REPO=${AMNEZIAWG_TOOLS_REPO:-https://github.com/amnezia-vpn/amneziawg-tools}
AMNEZIAWG_TOOLS_REF=${AMNEZIAWG_TOOLS_REF:-ee0f0a9aa34ff0a0da4b3433b9512781cfe02843}
AMNEZIAWG_DKMS_VERSION=${AMNEZIAWG_DKMS_VERSION:-1.0.0+y700.2}
AMNEZIAWG_DKMS_PKG_VERSION=${AMNEZIAWG_DKMS_PKG_VERSION:-1.0.0}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "$OUTPUT_DIR/.amneziawg-build.XXXXXX")

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

clone_ref() {
  local repo=$1 ref=$2 dest=$3
  ci_log "cloning $repo @$ref"
  git init "$dest"
  git -C "$dest" remote add origin "$repo"
  git -C "$dest" fetch --depth 1 origin "$ref"
  git -C "$dest" checkout --force FETCH_HEAD
}

if [ -z "$KERNEL_HEADERS_DEB" ]; then
  [ -n "$KERNEL_MODULES_DEB_DIR" ] || ci_die "KERNEL_HEADERS_DEB or KERNEL_MODULES_DEB_DIR is required"
  KERNEL_HEADERS_DEB=$(find "$(ci_abs_path "$KERNEL_MODULES_DEB_DIR")" -maxdepth 1 -type f -name 'y700-daily-kernel-headers_*.deb' | head -n1 || true)
fi
[ -n "$KERNEL_HEADERS_DEB" ] && [ -f "$KERNEL_HEADERS_DEB" ] || \
  ci_die "missing y700-daily-kernel-headers deb for AmneziaWG DKMS"

ci_log "extracting kernel headers: $KERNEL_HEADERS_DEB"
mkdir -p "$work_dir/headers"
dpkg-deb -x "$KERNEL_HEADERS_DEB" "$work_dir/headers"
hdrdir=$(find "$work_dir/headers" -type d -path '*/usr/src/linux-headers-*' | head -n1 || true)
[ -n "$hdrdir" ] && [ -f "$hdrdir/Makefile" ] || ci_die "headers deb did not contain /usr/src/linux-headers-*"
hdr_release=$(cat "$hdrdir/include/config/kernel.release" 2>/dev/null || true)
[ "$hdr_release" = "$KERNEL_ABI_RELEASE" ] || \
  ci_die "headers release ${hdr_release:-missing} does not match ABI $KERNEL_ABI_RELEASE"

clone_ref "$AMNEZIAWG_MODULE_REPO" "$AMNEZIAWG_MODULE_REF" "$work_dir/amneziawg-module"
clone_ref "$AMNEZIAWG_TOOLS_REPO" "$AMNEZIAWG_TOOLS_REF" "$work_dir/amneziawg-tools"

modsrc="$work_dir/amneziawg-module/src"
[ -f "$modsrc/Makefile" ] && [ -f "$modsrc/Kbuild" ] || ci_die "AmneziaWG module source missing Makefile/Kbuild"

ci_log "building amneziawg.ko against $KERNEL_ABI_RELEASE headers"
export IGNORE_CC_MISMATCH=1
make -C "$modsrc" -j"${KERNEL_BUILD_JOBS:-$(nproc)}" \
  KERNELDIR="$hdrdir" KERNELRELEASE="$KERNEL_ABI_RELEASE" IGNORE_CC_MISMATCH=1
ko=$(find "$modsrc" -maxdepth 1 -type f -name 'amneziawg.ko' | head -n1 || true)
[ -n "$ko" ] && [ -f "$ko" ] || ci_die "amneziawg.ko was not built"
vermagic=$(modinfo -F vermagic "$ko" | awk '{print $1}')
[ "$vermagic" = "$KERNEL_ABI_RELEASE" ] || \
  ci_die "amneziawg vermagic $vermagic does not match ABI $KERNEL_ABI_RELEASE"

dkms_conf_src="$REPO_ROOT/source/amneziawg/dkms.conf"
[ -f "$dkms_conf_src" ] || ci_die "missing $dkms_conf_src"
grep -q 'REMAKE_INITRD' "$dkms_conf_src" && ci_die "source dkms.conf must not set REMAKE_INITRD"
grep -q 'DEST_MODULE_LOCATION\[0\]="/updates"' "$dkms_conf_src" || \
  ci_die "source dkms.conf must install into /updates (rootfs module tree)"

policy_src="$REPO_ROOT/source/y700-dkms-rootfs-only"
[ -x "$policy_src/usr/lib/y700-dkms/skip-boot-tool" ] || ci_die "missing skip-boot-tool"
[ -x "$policy_src/usr/lib/y700-dkms/protect-boot-tools.sh" ] || ci_die "missing protect-boot-tools.sh"
[ -x "$policy_src/usr/lib/y700-dkms/install-pinned-module.sh" ] || ci_die "missing install-pinned-module.sh"
grep -q '^PACKAGE_NAME=amneziawg-dkms$' "$policy_src/usr/lib/y700-dkms/protect-boot-tools.sh" || \
  ci_die "boot-tool diverts must be owned by amneziawg-dkms"

# Single package: DKMS source, prebuilt .ko, userspace tools, boot/grub guards.
pkg="$work_dir/pkg/amneziawg-dkms"
dkms_src_dir="$pkg/usr/src/amneziawg-$AMNEZIAWG_DKMS_PKG_VERSION"
rm -rf "$pkg"
install -d -m 0755 "$dkms_src_dir" "$pkg/DEBIAN" \
  "$pkg/usr/lib/modules/$KERNEL_ABI_RELEASE/updates" \
  "$pkg/usr/lib/y700-dkms" \
  "$pkg/etc/modules-load.d" \
  "$pkg/usr/bin" \
  "$pkg/usr/lib/systemd/system" \
  "$pkg/usr/share/bash-completion/completions" \
  "$pkg/etc/amnezia/amneziawg"

rsync -a \
  --exclude '*.ko' --exclude '*.ko.*' --exclude '*.o' --exclude '*.mod.c' \
  --exclude '*.mod' --exclude '*.cmd' --exclude '.*.cmd' --exclude 'Module.symvers' \
  --exclude 'modules.order' --exclude '.tmp_versions' --exclude 'tests/' \
  "$modsrc/" "$dkms_src_dir/"
abi_regex=$(printf '%s' "$KERNEL_ABI_RELEASE" | sed 's/\./\\./g')
sed "s/__KERNEL_ABI_RELEASE__/${abi_regex}/g" "$dkms_conf_src" > "$dkms_src_dir/dkms.conf"
chmod 0644 "$dkms_src_dir/dkms.conf"
grep -q 'REMAKE_INITRD' "$dkms_src_dir/dkms.conf" && ci_die "packaged dkms.conf still enables REMAKE_INITRD"
grep -q "BUILD_EXCLUSIVE_KERNEL=\"^${abi_regex}\$\"" "$dkms_src_dir/dkms.conf" || \
  ci_die "packaged dkms.conf is not pinned to ABI $KERNEL_ABI_RELEASE"

install -m 0644 "$ko" "$pkg/usr/lib/modules/$KERNEL_ABI_RELEASE/updates/amneziawg.ko"
printf 'amneziawg\n' > "$pkg/etc/modules-load.d/amneziawg.conf"
chmod 0644 "$pkg/etc/modules-load.d/amneziawg.conf"

rsync -a "$policy_src/usr/lib/y700-dkms/" "$pkg/usr/lib/y700-dkms/"
chmod 0755 \
  "$pkg/usr/lib/y700-dkms/skip-boot-tool" \
  "$pkg/usr/lib/y700-dkms/protect-boot-tools.sh" \
  "$pkg/usr/lib/y700-dkms/install-pinned-module.sh"

ci_log "building amneziawg-tools into amneziawg-dkms"
make -C "$work_dir/amneziawg-tools/src" clean || true
make -C "$work_dir/amneziawg-tools/src" \
  WITH_WGQUICK=yes WITH_BASHCOMPLETION=yes WITH_SYSTEMDUNITS=yes \
  PREFIX=/usr SYSCONFDIR=/etc DESTDIR="$pkg" \
  BASHCOMPDIR=/usr/share/bash-completion/completions \
  SYSTEMDUNITDIR=/usr/lib/systemd/system \
  install
[ -x "$pkg/usr/bin/awg" ] || ci_die "amneziawg-tools did not install /usr/bin/awg"
[ -x "$pkg/usr/bin/awg-quick" ] || ci_die "amneziawg-tools did not install /usr/bin/awg-quick"

cat > "$pkg/DEBIAN/control" <<CTRL
Package: amneziawg-dkms
Version: $AMNEZIAWG_DKMS_VERSION
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: Y700 local build <root@localhost>
Depends: dkms, y700-daily-kernel-headers, iproute2
Recommends: iptables | nftables
Provides: amneziawg-tools, y700-dkms-rootfs-only
Replaces: amneziawg-tools, y700-dkms-rootfs-only
Conflicts: amneziawg-tools, y700-dkms-rootfs-only
Description: AmneziaWG DKMS module and tools for the pinned Y700 kernel ABI.
 Ships DKMS source, a prebuilt amneziawg.ko under
 /usr/lib/modules/$KERNEL_ABI_RELEASE/updates, awg/awg-quick, and boot/grub
 tool diverts so DKMS cannot rewrite the FAT boot partition. Does not run
 update-initramfs or grub.
CTRL

cat > "$pkg/DEBIAN/postinst" <<POST
#!/bin/sh
set -e
current_release="$KERNEL_ABI_RELEASE"
dkms_version="$AMNEZIAWG_DKMS_PKG_VERSION"
if [ "\$1" = configure ]; then
	if [ -x /usr/lib/y700-dkms/protect-boot-tools.sh ]; then
		/usr/lib/y700-dkms/protect-boot-tools.sh
	fi
	if command -v depmod >/dev/null 2>&1; then
		depmod "\$current_release" || true
	fi
	# Register source only. Do not compile against the host uname -r
	# (chroot/builder ABI is not the tablet ABI). Rootfs provision installs
	# the pinned module with install-pinned-module.sh.
	if command -v dkms >/dev/null 2>&1 && [ -d /usr/src/amneziawg-\$dkms_version ]; then
		dkms add -m amneziawg -v "\$dkms_version" >/dev/null 2>&1 || true
	fi
fi
exit 0
POST
chmod 0755 "$pkg/DEBIAN/postinst"

cat > "$pkg/DEBIAN/prerm" <<PRERM
#!/bin/sh
set -e
dkms_version="$AMNEZIAWG_DKMS_PKG_VERSION"
if [ "\$1" = remove ] || [ "\$1" = deconfigure ]; then
	if command -v dkms >/dev/null 2>&1; then
		dkms remove -m amneziawg -v "\$dkms_version" --all >/dev/null 2>&1 || true
	fi
fi
exit 0
PRERM
chmod 0755 "$pkg/DEBIAN/prerm"

# Drop leftover split packages from earlier builds of this output dir.
rm -f "$OUTPUT_DIR"/y700-dkms-rootfs-only_*.deb "$OUTPUT_DIR"/amneziawg-tools_*.deb
dkms_deb="$OUTPUT_DIR/amneziawg-dkms_${AMNEZIAWG_DKMS_VERSION}_arm64.deb"
rm -f "$dkms_deb"
dpkg-deb --root-owner-group --build "$pkg" "$dkms_deb"

deb_count=$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.deb' | wc -l)
[ "$deb_count" -eq 1 ] || ci_die "expected a single amneziawg-dkms deb in $OUTPUT_DIR, found $deb_count"

cat > "$OUTPUT_DIR/BUILD-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
kernel_abi_release=$KERNEL_ABI_RELEASE
headers_deb=$KERNEL_HEADERS_DEB
amneziawg_module_repo=$AMNEZIAWG_MODULE_REPO
amneziawg_module_ref=$AMNEZIAWG_MODULE_REF
amneziawg_tools_repo=$AMNEZIAWG_TOOLS_REPO
amneziawg_tools_ref=$AMNEZIAWG_TOOLS_REF
amneziawg_vermagic=$vermagic
package=amneziawg-dkms
combined_deb=yes
dest_module_location=/updates
remake_initrd=no
touches_boot=no
touches_grub=no
INFO

(cd "$OUTPUT_DIR" && sha256sum \
  "$(basename "$dkms_deb")" \
  BUILD-INFO.txt > SHA256SUMS.txt)

ci_log "AmneziaWG combined deb complete: $dkms_deb"
