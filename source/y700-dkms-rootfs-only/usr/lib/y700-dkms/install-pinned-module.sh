#!/bin/sh
set -e

usage() {
	echo "Usage: $0 MODULE VERSION KERNEL_RELEASE" >&2
	exit 2
}

[ $# -eq 3 ] || usage

MODULE=$1
VERSION=$2
KERNEL_RELEASE=$3
SKIP_TOOL=/usr/lib/y700-dkms/skip-boot-tool

if [ ! -x /usr/lib/y700-dkms/protect-boot-tools.sh ]; then
	echo "missing /usr/lib/y700-dkms/protect-boot-tools.sh" >&2
	exit 1
fi
/usr/lib/y700-dkms/protect-boot-tools.sh

command -v dkms >/dev/null 2>&1 || {
	echo "dkms is not installed" >&2
	exit 1
}

build_link=/usr/lib/modules/$KERNEL_RELEASE/build
if [ ! -e "$build_link" ] && [ -e "/lib/modules/$KERNEL_RELEASE/build" ]; then
	build_link=/lib/modules/$KERNEL_RELEASE/build
fi
[ -e "$build_link" ] || {
	echo "missing DKMS headers symlink: $build_link" >&2
	exit 1
}

boot_before=$(mktemp)
boot_after=$(mktemp)
trap 'rm -f "$boot_before" "$boot_after"' EXIT
if [ -d /boot ]; then
	find /boot -xdev \( -type f -o -type l \) -printf '%p %s %T@\n' 2>/dev/null | sort > "$boot_before" || true
else
	: > "$boot_before"
fi

export IGNORE_CC_MISMATCH=1
# Belt and suspenders if a caller restored the real tools in PATH.
export PATH="/usr/lib/y700-dkms:$PATH"
if [ -x "$SKIP_TOOL" ]; then
	ln -sfn "$SKIP_TOOL" /usr/lib/y700-dkms/update-initramfs
	ln -sfn "$SKIP_TOOL" /usr/lib/y700-dkms/update-grub
fi

if ! dkms status -m "$MODULE" -v "$VERSION" 2>/dev/null | grep -q "$MODULE"; then
	dkms add -m "$MODULE" -v "$VERSION"
fi

if ! dkms install -m "$MODULE" -v "$VERSION" -k "$KERNEL_RELEASE"; then
	dkms install -m "$MODULE" -v "$VERSION" -k "$KERNEL_RELEASE" --force
fi

modinfo_path=
for cand in \
	"/usr/lib/modules/$KERNEL_RELEASE/updates/${MODULE}.ko" \
	"/usr/lib/modules/$KERNEL_RELEASE/updates/${MODULE}.ko.xz" \
	"/usr/lib/modules/$KERNEL_RELEASE/updates/${MODULE}.ko.zst" \
	"/lib/modules/$KERNEL_RELEASE/updates/${MODULE}.ko" \
	"/lib/modules/$KERNEL_RELEASE/updates/${MODULE}.ko.xz" \
	"/lib/modules/$KERNEL_RELEASE/updates/${MODULE}.ko.zst"
do
	if [ -f "$cand" ]; then
		modinfo_path=$cand
		break
	fi
done
if [ -z "$modinfo_path" ]; then
	modinfo_path=$(find /usr/lib/modules/"$KERNEL_RELEASE" /lib/modules/"$KERNEL_RELEASE" \
		-type f \( -name "${MODULE}.ko" -o -name "${MODULE}.ko.xz" -o -name "${MODULE}.ko.zst" \) \
		! -path '*/kernel/*' 2>/dev/null | head -n1 || true)
fi
[ -n "$modinfo_path" ] || {
	echo "DKMS did not install $MODULE.ko under /lib/modules/$KERNEL_RELEASE (rootfs updates/extra)" >&2
	dkms status -m "$MODULE" -v "$VERSION" -k "$KERNEL_RELEASE" || true
	exit 1
}

case "$modinfo_path" in
	*/boot/*|*/grub/*)
		echo "refusing DKMS module installed onto boot/grub path: $modinfo_path" >&2
		exit 1
		;;
esac

if command -v modinfo >/dev/null 2>&1; then
	vermagic=$(modinfo -F vermagic "$modinfo_path" | awk '{print $1}')
	[ "$vermagic" = "$KERNEL_RELEASE" ] || {
		echo "module vermagic $vermagic does not match kernel ABI $KERNEL_RELEASE" >&2
		exit 1
	}
fi

if [ -d /boot ]; then
	find /boot -xdev \( -type f -o -type l \) -printf '%p %s %T@\n' 2>/dev/null | sort > "$boot_after" || true
else
	: > "$boot_after"
fi
if ! cmp -s "$boot_before" "$boot_after"; then
	echo "DKMS changed files under /boot; rootfs-only policy violated" >&2
	diff -u "$boot_before" "$boot_after" >&2 || true
	exit 1
fi

echo "y700-dkms: installed $MODULE/$VERSION for $KERNEL_RELEASE at $modinfo_path"
exit 0
