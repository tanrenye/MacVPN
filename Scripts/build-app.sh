#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --manifest-cache local -c release
build_path=$(swift build --disable-sandbox --manifest-cache local -c release --show-bin-path)
mkdir -p dist
staging=$(mktemp -d /private/tmp/macvpn-package.XXXXXXXX)
trap 'rm -rf "$staging"' EXIT

app="$staging/MacVPN.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$build_path/MacVPN" "$app/Contents/MacOS/MacVPN"
cp Scripts/Info.plist "$app/Contents/Info.plist"
if [[ "${1:-}" == "--with-engine" ]]; then
    engine="$PWD/.build/openvpn/bundle"
    /usr/bin/plutil -replace LSMinimumSystemVersion -string 15.0 "$app/Contents/Info.plist"
    install -m 755 "$engine/openvpn" "$app/Contents/MacOS/openvpn"
    install -m 755 "$build_path/MacVPNTunnelHelper" "$app/Contents/MacOS/MacVPNTunnelHelper"
    install -m 755 "$engine/dns-updown" "$app/Contents/Resources/dns-updown"
    cp "$engine/"*LICENSE* "$engine/"*COPYING "$app/Contents/Resources/"
    cp .build/openvpn/openvpn-*.tar.gz .build/lzo/lzo-*.tar.gz dist/
fi

cp Scripts/MacVPN.icns "$app/Contents/Resources/MacVPN.icns"
xattr -cr "$app"
if [[ -f "$app/Contents/MacOS/openvpn" ]]; then
    codesign --force --sign - "$app/Contents/MacOS/openvpn"
    codesign --force --options runtime --sign - "$app/Contents/MacOS/MacVPNTunnelHelper"
fi
codesign --force --options runtime --sign - "$app"
codesign --verify --deep --strict "$app"
(cd "$staging" && /usr/bin/zip -q -X -r MacVPN.zip MacVPN.app)

if [[ -d dist/MacVPN.app ]]; then
    mv dist/MacVPN.app "$staging/previous"
fi
mv "$app" dist/MacVPN.app
mv "$staging/MacVPN.zip" dist/MacVPN.zip
printf 'MacVPN.app 已生成于 %s\n' "$PWD/dist/MacVPN.app"
