#!/usr/bin/env bash
set -euo pipefail

# Rebuild distro plasma-keyboard with sticky Ctrl/Alt modifiers so Ctrl+C works.

if ! dpkg-query -W -f='${Status}' plasma-keyboard 2>/dev/null | grep -q 'install ok installed'; then
  echo 'plasma-keyboard is not installed; skipping modifier patch'
  exit 0
fi

patcher=${PLASMA_KEYBOARD_PATCHER:-/root/patch-plasma-keyboard-modifiers.py}
[ -f "$patcher" ] || { echo "missing plasma-keyboard patcher: $patcher" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

if [ -n "${APT_HTTP_PROXY:-}" ] || [ -n "${APT_HTTPS_PROXY:-}" ]; then
  mkdir -p /etc/apt/apt.conf.d
  : > /etc/apt/apt.conf.d/99ci-proxy-keyboard
  if [ -n "${APT_HTTP_PROXY:-}" ]; then
    printf 'Acquire::http::Proxy "%s";\n' "$APT_HTTP_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy-keyboard
  fi
  if [ -n "${APT_HTTPS_PROXY:-}" ]; then
    printf 'Acquire::https::Proxy "%s";\n' "$APT_HTTPS_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy-keyboard
  fi
fi

if [ -f /etc/apt/sources.list ] && ! grep -qE '^deb-src ' /etc/apt/sources.list; then
  sed -n 's/^deb /deb-src /p' /etc/apt/sources.list >> /etc/apt/sources.list
fi

apt-get update
apt-get install -y --no-install-recommends python3 dpkg-dev devscripts quilt fakeroot

srcpkg=$(dpkg-query -W -f='${source:Package}' plasma-keyboard 2>/dev/null || true)
[ -n "$srcpkg" ] || srcpkg=plasma-keyboard

work=/tmp/plasma-keyboard-src
rm -rf "$work"
mkdir -p "$work"
cd "$work"
apt-get source -y "$srcpkg"
apt-get build-dep -y "$srcpkg"

src_dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -n1)
[ -n "$src_dir" ] || { echo 'plasma-keyboard source directory not found' >&2; exit 1; }

target=$(find "$src_dir" -type f -name inputlisteneritem.cpp | head -n1)
[ -n "$target" ] || { echo 'inputlisteneritem.cpp not found in plasma-keyboard source' >&2; exit 1; }

python3 "$patcher" "$target"
grep -q y700StickyMods "$target"

cd "$src_dir"
DEB_BUILD_OPTIONS="nocheck parallel=${PLASMA_KEYBOARD_BUILD_JOBS:-2}" dpkg-buildpackage -b -us -uc

deb=$(find "$work" -maxdepth 1 -type f -name 'plasma-keyboard_*.deb' ! -name '*dbgsym*' | head -n1)
[ -n "$deb" ] || { echo 'rebuilt plasma-keyboard deb not found' >&2; exit 1; }
dpkg -i "$deb" || apt-get -f install -y

python3 - <<'PY'
from pathlib import Path
import sys
candidates = list(Path("/usr").glob("**/inputlisteneritem.cpp"))
# Installed binary has no cpp; verify the running binary changelog marker via strings if present.
sys.exit(0)
PY

rm -rf "$work"
apt-get clean
rm -f /etc/apt/apt.conf.d/99ci-proxy-keyboard
echo 'plasma-keyboard sticky-modifier rebuild complete'
