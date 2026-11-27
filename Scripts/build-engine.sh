#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD/.build/openvpn"
lzo_root="$PWD/.build/lzo"
version=2.7.9
archive="$root/openvpn-$version.tar.gz"
lzo_version=2.10
lzo_archive="$lzo_root/lzo-$lzo_version.tar.gz"
mkdir -p "$root" "$lzo_root"

if [[ $# -gt 0 ]]; then
    cp "$1" "$archive"
elif [[ ! -f "$archive" ]]; then
    curl --fail --location --output "$archive.download" "https://swupdate.openvpn.net/community/releases/openvpn-$version.tar.gz"
    mv "$archive.download" "$archive"
fi
printf '%s  %s\n' c42a6ed892ddfe2d6e3317a5040f19bec5827564affb2fe3f2b3904a94daacb1 "$archive" | /usr/bin/shasum -a 256 -c -

if [[ $# -gt 1 ]]; then
    cp "$2" "$lzo_archive"
elif [[ ! -f "$lzo_archive" ]]; then
    curl --fail --location --output "$lzo_archive.download" "https://www.oberhumer.com/opensource/lzo/download/lzo-$lzo_version.tar.gz"
    mv "$lzo_archive.download" "$lzo_archive"
fi
printf '%s  %s\n' c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072 "$lzo_archive" | /usr/bin/shasum -a 256 -c -

openssl=$(brew --prefix openssl@3)
lz4=$(brew --prefix lz4)
for file in "$openssl/lib/libssl.a" "$openssl/lib/libcrypto.a" "$lz4/lib/liblz4.a"; do
    if [[ ! -f "$file" ]]; then
        printf '缺少 %s。请先运行 brew install openssl@3 lz4 pkgconf。\n' "$file" >&2
        exit 1
    fi
done

export MACOSX_DEPLOYMENT_TARGET=15.0
jobs=$(sysctl -n hw.logicalcpu 2>/dev/null || printf 4)
lzo="$lzo_root/install"
lzo_source="$lzo_root/lzo-$lzo_version"
tar -xzf "$lzo_archive" -C "$lzo_root"
(
    cd "$lzo_source"
    ./configure --prefix="$lzo" --disable-shared --enable-static
    make -j "$jobs"
    make install
)

tar -xzf "$archive" -C "$root"
source_dir="$root/openvpn-$version"
cd "$source_dir"
export OPENSSL_CFLAGS="-I$openssl/include"
export OPENSSL_LIBS="$openssl/lib/libssl.a $openssl/lib/libcrypto.a"
export LZ4_CFLAGS="-I$lz4/include"
export LZ4_LIBS="$lz4/lib/liblz4.a"
export LZO_CFLAGS="-I$lzo/include"
export LZO_LIBS="$lzo/lib/liblzo2.a"
export LDFLAGS="-L$lz4/lib -L$lzo/lib"
./configure --disable-dco --disable-debug
make config-version.h
make -C src/compat
make -j "$jobs" -C src/openvpn

mkdir -p "$root/bundle"
install -m 755 src/openvpn/openvpn "$root/bundle/openvpn"
install -m 755 distro/dns-scripts/macos-dns-updown.sh "$root/bundle/dns-updown"
cp COPYING "$root/bundle/OpenVPN-COPYING"
cp "$lzo_source/COPYING" "$root/bundle/LZO-COPYING"
cp "$openssl/LICENSE.txt" "$root/bundle/OpenSSL-LICENSE.txt"
cp "$lz4/LICENSE" "$root/bundle/LZ4-LICENSE"
"$root/bundle/openvpn" --version
