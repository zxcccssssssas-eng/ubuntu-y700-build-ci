#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Rebuild the TB321FU kernel with Ubuntu-like extra features while keeping the
existing kernel ABI/vermagic.

Environment inputs:
  OUTPUT_DIR                 default: out/ci-kernel
  KERNEL_SOURCE_REPO         default: https://github.com/GUF296/linux
  KERNEL_SOURCE_REF          git commit/branch, default: 5df8e852ea722929f5359a5ef28ebcec0c4443fd
  KERNEL_SOURCE_DIR          optional existing kernel checkout
  KERNEL_ARTIFACT_ARCHIVE    archive providing baseline kernel.config
  KERNEL_BASE_CONFIG         optional explicit baseline .config path
  KERNEL_FRAGMENT            default: source/kernel/ubuntu-features.config
  KERNEL_ABI_RELEASE         expected UTS release, default: 7.1.1-g5df8e852ea72
  KERNEL_ABI_LOCALVERSION    default: -g5df8e852ea72
                             (LOCALVERSION is forced empty so setlocalversion
                             does not append "+" on this untagged tree)
  DTB_NAME                   default: sm8650-lenovo-tb321fu.dtb
  KERNEL_BUILD_JOBS          default: nproc
  KERNEL_MODULES_DEB_VERSION default: 0.1+ubuntu-features.1
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd make
ci_require_cmd tar
ci_require_cmd rsync
ci_require_cmd sha256sum
ci_require_cmd dpkg-deb
ci_require_cmd git
ci_require_cmd flex
ci_require_cmd bison
ci_require_cmd bc

OUTPUT_DIR=${OUTPUT_DIR:-out/ci-kernel}
KERNEL_SOURCE_REPO=${KERNEL_SOURCE_REPO:-https://github.com/GUF296/linux}
KERNEL_SOURCE_REF=${KERNEL_SOURCE_REF:-5df8e852ea722929f5359a5ef28ebcec0c4443fd}
KERNEL_SOURCE_DIR=${KERNEL_SOURCE_DIR:-}
KERNEL_ARTIFACT_ARCHIVE=${KERNEL_ARTIFACT_ARCHIVE:-}
KERNEL_BASE_CONFIG=${KERNEL_BASE_CONFIG:-}
KERNEL_FRAGMENT=${KERNEL_FRAGMENT:-"$REPO_ROOT/source/kernel/ubuntu-features.config"}
KERNEL_ABI_RELEASE=${KERNEL_ABI_RELEASE:-7.1.1-g5df8e852ea72}
KERNEL_ABI_LOCALVERSION=${KERNEL_ABI_LOCALVERSION:--g5df8e852ea72}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
KERNEL_BUILD_JOBS=${KERNEL_BUILD_JOBS:-$(nproc)}
KERNEL_MODULES_DEB_VERSION=${KERNEL_MODULES_DEB_VERSION:-0.1+ubuntu-features.1}
ARCH_NAME=${ARCH:-arm64}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "$OUTPUT_DIR/.kernel-build.XXXXXX")

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]; then
  CROSS_COMPILE=${CROSS_COMPILE:-}
else
  ci_require_cmd aarch64-linux-gnu-gcc
  CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
fi

if [ -z "$KERNEL_BASE_CONFIG" ]; then
  [ -n "$KERNEL_ARTIFACT_ARCHIVE" ] || ci_die "KERNEL_BASE_CONFIG or KERNEL_ARTIFACT_ARCHIVE is required"
  archive="$work_dir/kernel-artifacts.archive"
  ci_download "$KERNEL_ARTIFACT_ARCHIVE" "$archive"
  ci_extract_archive "$archive" "$work_dir/kernel-artifacts"
  KERNEL_BASE_CONFIG=$(find "$work_dir/kernel-artifacts" -type f -name kernel.config | head -n1 || true)
  [ -n "$KERNEL_BASE_CONFIG" ] || ci_die "KERNEL_ARTIFACT_ARCHIVE did not contain kernel.config"
fi
[ -f "$KERNEL_BASE_CONFIG" ] || ci_die "missing baseline kernel config: $KERNEL_BASE_CONFIG"
[ -f "$KERNEL_FRAGMENT" ] || ci_die "missing kernel fragment: $KERNEL_FRAGMENT"
if grep -q '^CONFIG_DEBUG_INFO_BTF=y' "$KERNEL_FRAGMENT"; then
  ci_require_cmd pahole
fi

if [ -n "$KERNEL_SOURCE_DIR" ]; then
  src=$(ci_abs_path "$KERNEL_SOURCE_DIR")
  [ -f "$src/Makefile" ] || ci_die "KERNEL_SOURCE_DIR is not kernel source: $src"
else
  src="$work_dir/linux"
  ci_log "cloning kernel $KERNEL_SOURCE_REPO @$KERNEL_SOURCE_REF"
  git init "$src"
  git -C "$src" remote add origin "$KERNEL_SOURCE_REPO"
  git -C "$src" fetch --depth 1 origin "$KERNEL_SOURCE_REF"
  git -C "$src" checkout --force FETCH_HEAD
fi

build="$work_dir/build"
mkdir -p "$build"
cp -a "$KERNEL_BASE_CONFIG" "$build/.config"

if [ -x "$src/scripts/kconfig/merge_config.sh" ]; then
  ci_log "merging Ubuntu-like feature fragment"
  "$src/scripts/kconfig/merge_config.sh" -m -O "$build" "$build/.config" "$KERNEL_FRAGMENT"
else
  cat "$KERNEL_FRAGMENT" >> "$build/.config"
fi

# Pin vermagic/UTS release so existing out-of-tree modules keep loading.
{
  echo "CONFIG_LOCALVERSION=\"$KERNEL_ABI_LOCALVERSION\""
  echo "# CONFIG_LOCALVERSION_AUTO is not set"
} >> "$build/.config"

# scripts/setlocalversion appends "+" when LOCALVERSION is unset and HEAD is
# not an annotated v$(KERNELVERSION) tag. This Qualcomm tree is a shallow
# clone of 5df8e852ea72, so an unset LOCALVERSION yields
# 7.1.1-g5df8e852ea72+ and breaks ABI/vermagic. An empty-but-set value
# keeps UTS_RELEASE at KERNEL_ABI_RELEASE. Do not inherit a caller value.
export LOCALVERSION=

make_k() {
  make -C "$src" O="$build" ARCH="$ARCH_NAME" CROSS_COMPILE="$CROSS_COMPILE" \
    LOCALVERSION= \
    KCFLAGS="${KCFLAGS:-}" HOSTCFLAGS="${HOSTCFLAGS:-}" \
    -j"$KERNEL_BUILD_JOBS" "$@"
}

assert_kernel_release() {
  local stage=$1
  local release
  [ -f "$build/include/config/kernel.release" ] || \
    ci_die "missing include/config/kernel.release after $stage"
  release=$(cat "$build/include/config/kernel.release")
  ci_log "kernel.release after $stage: $release"
  [ "$release" = "$KERNEL_ABI_RELEASE" ] || \
    ci_die "kernel release $release does not match ABI $KERNEL_ABI_RELEASE after $stage"
}

ci_log "olddefconfig"
make_k olddefconfig

# Re-assert ABI localversion after olddefconfig.
if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "$build/.config"; then
  sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$build/.config"
fi
sed -i "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"$KERNEL_ABI_LOCALVERSION\"/" "$build/.config"
if ! grep -q "^CONFIG_LOCALVERSION=" "$build/.config"; then
  echo "CONFIG_LOCALVERSION=\"$KERNEL_ABI_LOCALVERSION\"" >> "$build/.config"
fi
make_k olddefconfig
# olddefconfig only refreshes .config; materialize the same kernel.release
# the Image build will use so an ABI mismatch fails before a 30-minute compile.
make_k include/config/auto.conf include/config/kernel.release
assert_kernel_release olddefconfig

required_opts=(
  CONFIG_WIREGUARD
  CONFIG_TCP_CONG_BBR
  CONFIG_DEBUG_INFO_BTF
  CONFIG_KVM
  CONFIG_TUN
  CONFIG_NF_TABLES
  CONFIG_VETH
  CONFIG_IP_ADVANCED_ROUTER
  CONFIG_IP_MULTIPLE_TABLES
  CONFIG_FIB_RULES
)
for opt in "${required_opts[@]}"; do
  grep -qE "^${opt}=[ym]$" "$build/.config" || ci_die "required kernel option missing after merge: $opt"
done
grep -q '^CONFIG_DEBUG_INFO_REDUCED=y' "$build/.config" && ci_die "CONFIG_DEBUG_INFO_REDUCED is still enabled; BTF needs full debug info"

ci_log "building Image, DTBs and modules"
make_k Image dtbs modules
assert_kernel_release build
release=$(cat "$build/include/config/kernel.release")

image=$(find "$build" -type f -path '*/arch/arm64/boot/Image' | head -n1 || true)
dtb=$(find "$build" -type f -name "$DTB_NAME" | head -n1 || true)
[ -n "$image" ] && [ -f "$image" ] || ci_die "missing built Image"
[ -n "$dtb" ] && [ -f "$dtb" ] || ci_die "missing built DTB: $DTB_NAME"

pkg="$work_dir/pkg/y700-daily-kernel-modules"
install -d -m 0755 "$pkg/DEBIAN" "$pkg/usr/lib/modules"
make_k INSTALL_MOD_PATH="$pkg/usr" INSTALL_MOD_STRIP=1 modules_install
rm -f "$pkg/usr/lib/modules/$release/build" "$pkg/usr/lib/modules/$release/source"
[ -d "$pkg/usr/lib/modules/$release" ] || ci_die "modules_install did not create $release"

cat > "$pkg/DEBIAN/control" <<CTRL
Package: y700-daily-kernel-modules
Version: $KERNEL_MODULES_DEB_VERSION
Section: misc
Priority: optional
Architecture: arm64
Maintainer: Y700 local build <root@localhost>
Replaces: y700-daily-kernel-modules (<< $KERNEL_MODULES_DEB_VERSION)
Description: Lenovo Y700 kernel modules for $release with Ubuntu-like extra features.
CTRL

cat > "$pkg/DEBIAN/postinst" <<POST
#!/bin/sh
set -e
current_release="$release"
for base in /usr/lib/modules /lib/modules; do
	[ -d "\$base" ] || continue
	for dir in "\$base"/*; do
		[ -d "\$dir" ] || continue
		rel=\${dir##*/}
		if [ "\$rel" != "\$current_release" ]; then
			rm -rf "\$dir"
		fi
	done
done
modroot="/usr/lib/modules/$release"
if [ -d "\$modroot" ]; then
	find "\$modroot" -type f -name '*.ko' ! -path '*/kernel/*' ! -path '*/extra/*' -delete
	find "\$modroot" -type f \\( -name '*.bak*' -o -name '*.pre-*' -o -name '*.orig' -o -name '*.rej' \\) -delete
fi
if command -v depmod >/dev/null 2>&1; then
	depmod "$release" || true
fi
exit 0
POST
chmod 0755 "$pkg/DEBIAN/postinst"

deb="$OUTPUT_DIR/y700-daily-kernel-modules_${KERNEL_MODULES_DEB_VERSION}_arm64.deb"
rm -f "$deb"
dpkg-deb --root-owner-group --build "$pkg" "$deb"

art_dir="$work_dir/artifacts"
mkdir -p "$art_dir"
cp -a "$image" "$art_dir/Image"
cp -a "$dtb" "$art_dir/$DTB_NAME"
cp -a "$build/.config" "$art_dir/kernel.config"
cat > "$art_dir/BUILD-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
kernel_source_repo=$KERNEL_SOURCE_REPO
kernel_source_ref=$KERNEL_SOURCE_REF
kernel_release=$release
kernel_abi_release=$KERNEL_ABI_RELEASE
dtb_name=$DTB_NAME
fragment=$(ci_abs_path "$KERNEL_FRAGMENT")
INFO

cp -a "$art_dir/Image" "$OUTPUT_DIR/Image"
cp -a "$art_dir/$DTB_NAME" "$OUTPUT_DIR/$DTB_NAME"
cp -a "$art_dir/kernel.config" "$OUTPUT_DIR/kernel.config"
cp -a "$art_dir/BUILD-INFO.txt" "$OUTPUT_DIR/kernel.BUILD-INFO.txt"

tarball="$OUTPUT_DIR/y700-kernel-artifacts-${release}.tar.gz"
tar -C "$art_dir" -czf "$tarball" Image "$DTB_NAME" kernel.config BUILD-INFO.txt

(cd "$OUTPUT_DIR" && sha256sum "$(basename "$deb")" "$(basename "$tarball")" Image kernel.config "$DTB_NAME" kernel.BUILD-INFO.txt > SHA256SUMS.txt)

ci_log "kernel build complete: $OUTPUT_DIR"
ci_log "modules deb: $deb"
ci_log "artifacts: $tarball"
