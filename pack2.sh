#!/usr/bin/env bash
# 为 zfiglet / ztoilet / zfetch 打包；前两个把 textfig 一起塞进 tarball
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
ws="$(cd "$root/.." && pwd)"
out="$root/packages"
mkdir -p "$out"

build_pkg() {
  local pkg="$1" ver="$2" desc="$3" dir="$4"
  shift 4
  local -a srcs=("$@")
  local work="$out/$pkg"
  mkdir -p "$work"
  if ls "$work"/*.pkg.tar.zst >/dev/null 2>&1; then
    echo "skip $pkg"
    return 0
  fi
  tar czf "$work/$pkg-$ver.tar.gz" -C "$root" \
    --exclude='.zig-cache' --exclude='zig-out' "${srcs[@]}"
  cat > "$work/PKGBUILD" <<EOF
pkgname=$pkg
pkgver=$ver
pkgrel=1
pkgdesc="$desc"
arch=('x86_64')
url=""
license=('MIT')
makedepends=('zig')
depends=('zlib')
source=("\$pkgname-\$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
  cd "\$srcdir/$dir"
  ZIG_GLOBAL_CACHE_DIR="\$srcdir/.zig-global" zig build -Doptimize=ReleaseFast \\
    --prefix "\$srcdir/out" --cache-dir "\$srcdir/.zig-cache"
}

package() {
  install -Dm755 "\$srcdir/out/bin/$pkg" "\$pkgdir/usr/bin/$pkg"
  install -Dm644 "$dir/README.md" "\$pkgdir/usr/share/doc/\$pkgname/README.md"
}
EOF
  ( cd "$work" && makepkg -f --noconfirm >/dev/null )
  ls -1 "$work"/*.pkg.tar.zst
}

ver_of() { grep -m1 '\.version' "$1/build.zig.zon" | sed 's/.*"\(.*\)".*/\1/'; }

build_pkg zfiglet "$(ver_of "$root/zfiglet")" "FIGlet clone written in Zig (zfiglet)" zfiglet zfiglet textfig
build_pkg ztoilet "$(ver_of "$root/ztoilet")" "TOIlet clone written in Zig (ztoilet)" ztoilet ztoilet textfig

# zfetch 在 workspace 下，tarball 里放同名目录
if [ ! -e "$out/zfetch"/*.pkg.tar.zst ] 2>/dev/null; then :; fi
mkdir -p "$out/zfetch"
if ! ls "$out/zfetch"/*.pkg.tar.zst >/dev/null 2>&1; then
  ver="$(ver_of "$ws/zfetch")"
  tar czf "$out/zfetch/zfetch-$ver.tar.gz" -C "$ws" \
    --exclude='zfetch/.zig-cache' --exclude='zfetch/zig-out' \
    zfetch fastfetch/src/logo
  cat > "$out/zfetch/PKGBUILD" <<EOF
pkgname=zfetch
pkgver=$ver
pkgrel=1
pkgdesc="fastfetch clone written in Zig"
arch=('x86_64')
url=""
license=('MIT')
makedepends=('zig' 'fastfetch')
source=("\$pkgname-\$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
  cd "\$srcdir/zfetch"
  ZIG_GLOBAL_CACHE_DIR="\$srcdir/.zig-global" zig build -Doptimize=ReleaseFast \\
    --prefix "\$srcdir/out" --cache-dir "\$srcdir/.zig-cache"
}

package() {
  cd "\$srcdir/zfetch"
  install -Dm755 "\$srcdir/out/bin/zfetch" "\$pkgdir/usr/bin/zfetch"
  install -Dm644 README.md "\$pkgdir/usr/share/doc/\$pkgname/README.md"
  install -Dm644 LICENSE "\$pkgdir/usr/share/licenses/\$pkgname/LICENSE"
}
EOF
  ( cd "$out/zfetch" && makepkg -f --noconfirm >/dev/null )
  ls -1 "$out/zfetch"/*.pkg.tar.zst
fi
