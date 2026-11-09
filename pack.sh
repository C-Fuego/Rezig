#!/usr/bin/env bash
# 为 Rezig 下各项目生成 PKGBUILD 并打包（不安装）
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
out="$root/packages"
mkdir -p "$out"

MIT='MIT License

Copyright (c) 2026 ignacio

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.'

# 参数：包名 源码目录 二进制名 描述
pack() {
  local pkg="$1" dir="$2" bin="$3" desc="$4"
  local ver
  ver="$(grep -m1 '\.version' "$root/$dir/build.zig.zon" | sed 's/.*"\(.*\)".*/\1/')"
  local work="$out/$pkg"
  mkdir -p "$work"
  if ls "$work"/*.pkg.tar.zst >/dev/null 2>&1; then
    echo "skip $pkg (already built)"
    return 0
  fi
  if [ ! -f "$root/$dir/LICENSE" ]; then
    printf '%s\n' "$MIT" > "$root/$dir/LICENSE"
  fi
  tar czf "$work/$pkg-$ver.tar.gz" -C "$root" \
    --exclude="$dir/.zig-cache" --exclude="$dir/zig-out" "$dir"
  cat > "$work/PKGBUILD" <<EOF
pkgname=$pkg
pkgver=$ver
pkgrel=1
pkgdesc="$desc"
arch=('x86_64')
url=""
license=('MIT')
makedepends=('zig')
source=("\$pkgname-\$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
  cd "\$srcdir/$dir"
  ZIG_GLOBAL_CACHE_DIR="\$srcdir/.zig-global" zig build -Doptimize=ReleaseFast \\
    --prefix "\$srcdir/out" --cache-dir "\$srcdir/.zig-cache"
}

package() {
  install -Dm755 "\$srcdir/out/bin/$bin" "\$pkgdir/usr/bin/$bin"
  install -Dm644 "$dir/README.md" "\$pkgdir/usr/share/doc/\$pkgname/README.md"
  install -Dm644 "$dir/LICENSE" "\$pkgdir/usr/share/licenses/\$pkgname/LICENSE"
}
EOF
  ( cd "$work" && makepkg -f --noconfirm >/dev/null )
  ls -1 "$work"/*.pkg.tar.zst
}

pack zmatrix  zmatrix  zmatrix "cmatrix clone written in Zig"
pack zlolcat  zlolcat  zlolcat "lolcat clone written in Zig"
pack zbonsai  zbonsai  zbonsai "cbonsai clone written in Zig"
pack zclock   zclock   zclock  "tty-clock clone written in Zig"
pack pipes-zig zpipes  zpipes  "pipes.sh clone written in Zig"
