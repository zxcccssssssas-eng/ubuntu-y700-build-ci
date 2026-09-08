#!/bin/sh
set -e

PACKAGE_NAME=amneziawg-dkms
SKIP_TOOL=/usr/lib/y700-dkms/skip-boot-tool

log() {
	printf 'y700-dkms: %s\n' "$*"
}

pkg_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

write_file() {
	dest=$1
	install -d -m 0755 "$(dirname "$dest")"
	cat > "$dest"
	chmod 0644 "$dest"
}

protect_tool() {
	tool=$1
	install -d -m 0755 "$(dirname "$tool")"
	if ! dpkg-divert --list "$tool" 2>/dev/null | grep -q "$PACKAGE_NAME"; then
		dpkg-divert --package "$PACKAGE_NAME" --add --rename --divert "${tool}.y700-real" "$tool"
	fi
	ln -sfn "$SKIP_TOOL" "$tool"
}

[ -x "$SKIP_TOOL" ] || {
	echo "missing $SKIP_TOOL" >&2
	exit 1
}

# Divert first. Do not plant package conffiles before apt unpacks them;
# that makes dpkg stop at a noninteractive conffile prompt.
protect_tool /usr/sbin/update-initramfs
protect_tool /usr/sbin/update-grub
protect_tool /usr/sbin/update-grub2
protect_tool /usr/sbin/grub-install
protect_tool /usr/sbin/grub-mkconfig
protect_tool /usr/sbin/grub-mkdevicemap

for hook in \
	/etc/kernel/postinst.d/initramfs-tools \
	/etc/kernel/postinst.d/zz-update-grub \
	/etc/kernel/postrm.d/zz-update-grub \
	/etc/kernel/postinst.d/xx-update-initramfs \
	/etc/kernel/postinst.d/dracut \
	/usr/share/kernel/postinst.d/initramfs-tools \
	/usr/share/kernel/postinst.d/zz-update-grub
do
	protect_tool "$hook"
done

if pkg_installed linux-base || [ -e /etc/kernel-img.conf ]; then
	write_file /etc/kernel-img.conf <<'EOF'
do_symlinks = no
do_bootloader = no
do_initrd = no
no_initrd = yes
link_in_boot = no
ignore_depmod = no
EOF
fi

if pkg_installed initramfs-tools || [ -d /etc/initramfs-tools ]; then
	write_file /etc/initramfs-tools/update-initramfs.conf <<'EOF'
update_initramfs=no
backup_initramfs=no
EOF
	write_file /etc/initramfs-tools/conf.d/y700-rootfs-only.conf <<'EOF'
update_initramfs=no
EOF
fi

if pkg_installed dkms || [ -d /etc/dkms ]; then
	write_file /etc/dkms/framework.conf.d/00-y700-rootfs-only.conf <<'EOF'
# DKMS on this image must stay on the rootfs module tree.
# Boot Image/DTB/GRUB are on a separate FAT partition and must not be rewritten.
# update-initramfs and grub tools are diverted to skip-boot-tool.
EOF
fi

log "boot/grub tools diverted; DKMS limited to rootfs module paths"
exit 0
