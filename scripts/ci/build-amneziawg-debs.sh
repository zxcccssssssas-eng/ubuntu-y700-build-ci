#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build AmneziaWG DKMS source, userspace tools, and the rootfs-only DKMS policy
debs. The kernel module is compiled against the pinned Y700 headers and
installed only under /lib/modules/<abi>/updates on rootfs.

Environment inputs:
  OUTPUT_DIR                 default: out/amneziawg-debs
  KERNEL_MODULES_DEB_DIR     directory containing y700-daily-kernel-headers_*.deb
  KERNEL_HEADERS_DEB         optional explicit headers deb path
  KERNEL_ABI_RELEASE         default: 7.1.1-g5df8e852ea72
  AMNEZIAWG_MODULE_REPO      default: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
  AMNEZIAWG_MODULE_REF       git commit, default: 4569c4c67f3a57414969260cafbbd04694fbaae0
  AMNEZIAWG_TOOLS_REPO       default: https://github.com/amnezia-vpn/amneziawg-tools
  AMNEZIAWG_TOOLS_REF        git commit, default: ee0f0a9aa34ff0a0da4b3433b9512781cfe02843
  AMNEZIAWG_DKMS_VERSION     Debian version, default: 1.0.0+y700.1
  AMNEZIAWG_TOOLS_VERSION    Debian version, default: 1.0.20260812+y700
  AMNEZIAWG_POLICY_VERSION   Debian version, default: 1.0
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
AMNEZIAWG_DKMS_VERSION=${AMNEZIAWG_DKMS_VERSION:-1.0.0+y700.1}
AMNEZIAWG_TOOLS_VERSION=${AMNEZIAWG_TOOLS_VERSION:-1.0.20260812+y700}
AMNEZIAWG_POLICY_VERSION=${AMNEZIAWG_POLICY_VERSION:-1.0}
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

# Policy package: wrappers live on rootfs and divert boot/grub tools.
policy_src="$REPO_ROOT/source/y700-dkms-rootfs-only"
policy_pkg="$work_dir/pkg/y700-dkms-rootfs-only"
rm -rf "$policy_pkg"
install -d -m 0755 "$policy_pkg/DEBIAN" "$policy_pkg/usr/lib/y700-dkms"
rsync -a "$policy_src/usr/lib/y700-dkms/" "$policy_pkg/usr/lib/y700-dkms/"
chmod 0755 \
  "$policy_pkg/usr/lib/y700-dkms/skip-boot-tool" \
  "$policy_pkg/usr/lib/y700-dkms/protect-boot-tools.sh" \
  "$policy_pkg/usr/lib/y700-dkms/install-pinned-module.sh"

cat > "$policy_pkg/DEBIAN/control" <<CTRL
Package: y700-dkms-rootfs-only
Version: $AMNEZIAWG_POLICY_VERSION
Section: admin
Priority: optional
Architecture: all
Maintainer: Y700 local build <root@localhost>
Depends: dkms
Description: Keep DKMS on the Y700 rootfs module tree.
 Diverts update-initramfs and GRUB tools so DKMS cannot rewrite the FAT
 boot/GRUB partition. Modules stay under /lib/modules on rootfs.
CTRL

cat > "$policy_pkg/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ -x /usr/lib/y700-dkms/protect-boot-tools.sh ]; then
	/usr/lib/y700-dkms/protect-boot-tools.sh
fi
exit 0
POST
chmod 0755 "$policy_pkg/DEBIAN/postinst"

policy_deb="$OUTPUT_DIR/y700-dkms-rootfs-only_${AMNEZIAWG_POLICY_VERSION}_all.deb"
rm -f "$policy_deb"
dpkg-deb --root-owner-group --build "$policy_pkg" "$policy_deb"

# DKMS source package plus a prebuilt .ko for the pinned ABI.
dkms_pkg="$work_dir/pkg/amneziawg-dkms"
dkms_src_dir="$dkms_pkg/usr/src/amneziawg-$AMNEZIAWG_DKMS_PKG_VERSION"
rm -rf "$dkms_pkg"
install -d -m 0755 "$dkms_src_dir" "$dkms_pkg/DEBIAN" \
  "$dkms_pkg/usr/lib/modules/$KERNEL_ABI_RELEASE/updates" \
  "$dkms_pkg/etc/modules-load.d"

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

install -m 0644 "$ko" "$dkms_pkg/usr/lib/modules/$KERNEL_ABI_RELEASE/updates/amneziawg.ko"
printf 'amneziawg\n' > "$dkms_pkg/etc/modules-load.d/amneziawg.conf"
chmod 0644 "$dkms_pkg/etc/modules-load.d/amneziawg.conf"

cat > "$dkms_pkg/DEBIAN/control" <<CTRL
Package: amneziawg-dkms
Version: $AMNEZIAWG_DKMS_VERSION
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: Y700 local build <root@localhost>
Depends: dkms, y700-daily-kernel-headers, y700-dkms-rootfs-only
Description: AmneziaWG kernel module for the pinned Y700 kernel ABI.
 Ships DKMS source and a prebuilt amneziawg.ko under
 /usr/lib/modules/$KERNEL_ABI_RELEASE/updates. Does not touch /boot or GRUB.
CTRL

cat > "$dkms_pkg/DEBIAN/postinst" <<POST
#!/bin/sh
set -e
current_release="$KERNEL_ABI_RELEASE"
if command -v depmod >/dev/null 2>&1; then
	depmod "\$current_release" || true
fi
if command -v dkms >/dev/null 2>&1 && [ -d /usr/src/amneziawg-$AMNEZIAWG_DKMS_PKG_VERSION ]; then
	dkms add -m amneziawg -v $AMNEZIAWG_DKMS_PKG_VERSION >/dev/null 2>&1 || true
fi
exit 0
POST
chmod 0755 "$dkms_pkg/DEBIAN/postinst"

dkms_deb="$OUTPUT_DIR/amneziawg-dkms_${AMNEZIAWG_DKMS_VERSION}_arm64.deb"
rm -f "$dkms_deb"
dpkg-deb --root-owner-group --build "$dkms_pkg" "$dkms_deb"

# Userspace tools: awg / awg-quick.
tools_pkg="$work_dir/pkg/amneziawg-tools"
rm -rf "$tools_pkg"
install -d -m 0755 "$tools_pkg/DEBIAN" "$tools_pkg/usr/bin" "$tools_pkg/usr/lib/systemd/system" \
  "$tools_pkg/usr/share/bash-completion/completions" "$tools_pkg/etc/amnezia/amneziawg"
ci_log "building amneziawg-tools"
make -C "$work_dir/amneziawg-tools/src" clean || true
make -C "$work_dir/amneziawg-tools/src" \
  WITH_WGQUICK=yes WITH_BASHCOMPLETION=yes WITH_SYSTEMDUNITS=yes \
  PREFIX=/usr SYSCONFDIR=/etc DESTDIR="$tools_pkg" \
  BASHCOMPDIR=/usr/share/bash-completion/completions \
  SYSTEMDUNITDIR=/usr/lib/systemd/system \
  install
[ -x "$tools_pkg/usr/bin/awg" ] || ci_die "amneziawg-tools did not install /usr/bin/awg"
[ -x "$tools_pkg/usr/bin/awg-quick" ] || ci_die "amneziawg-tools did not install /usr/bin/awg-quick"

cat > "$tools_pkg/DEBIAN/control" <<CTRL
Package: amneziawg-tools
Version: $AMNEZIAWG_TOOLS_VERSION
Section: net
Priority: optional
Architecture: arm64
Maintainer: Y700 local build <root@localhost>
Depends: iproute2
Recommends: amneziawg-dkms, iptables | nftables
Description: AmneziaWG userspace tools (awg, awg-quick) for Y700.
CTRL

tools_deb="$OUTPUT_DIR/amneziawg-tools_${AMNEZIAWG_TOOLS_VERSION}_arm64.deb"
rm -f "$tools_deb"
dpkg-deb --root-owner-group --build "$tools_pkg" "$tools_deb"

cat > "$OUTPUT_DIR/BUILD-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
kernel_abi_release=$KERNEL_ABI_RELEASE
headers_deb=$KERNEL_HEADERS_DEB
amneziawg_module_repo=$AMNEZIAWG_MODULE_REPO
amneziawg_module_ref=$AMNEZIAWG_MODULE_REF
amneziawg_tools_repo=$AMNEZIAWG_TOOLS_REPO
amneziawg_tools_ref=$AMNEZIAWG_TOOLS_REF
amneziawg_vermagic=$vermagic
dest_module_location=/updates
remake_initrd=no
INFO

(cd "$OUTPUT_DIR" && sha256sum \
  "$(basename "$policy_deb")" \
  "$(basename "$dkms_deb")" \
  "$(basename "$tools_deb")" \
  BUILD-INFO.txt > SHA256SUMS.txt)

ci_log "AmneziaWG debs complete: $OUTPUT_DIR"
ci_log "policy: $policy_deb"
ci_log "dkms: $dkms_deb"
ci_log "tools: $tools_deb"
