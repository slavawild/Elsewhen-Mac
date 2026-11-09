#!/bin/bash
# Builds Elsewhen.app (universal, ad-hoc signed) into build/, and zips it.
#
#   scripts/build-app.sh            # release, arm64 + x86_64
#   ARCHS=arm64 scripts/build-app.sh

set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
version="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
archs="${ARCHS:-arm64 x86_64}"

arch_flags=()
for a in $archs; do arch_flags+=(--arch "$a"); done

swift build -c release "${arch_flags[@]}"
bin="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

app="$root/build/Elsewhen.app"
rm -rf "$root/build"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin/Elsewhen" "$app/Contents/MacOS/Elsewhen"
# SwiftPM's resource bundles: the data files, and the strings.
for bundle in "$bin"/*.bundle; do cp -R "$bundle" "$app/Contents/Resources/"; done
cp Support/AppIcon.icns "$app/Contents/Resources/" 2>/dev/null || true

# Every language the strings come in, so macOS lets the app speak it.
localizations=""
for dir in Sources/Elsewhen/Resources/*.lproj; do
  localizations+="    <string>$(basename "$dir" .lproj)</string>"$'\n'
done

sed -e "s/__VERSION__/$version/g" Support/Info.plist > "$app/Contents/Info.plist"
/usr/bin/python3 - "$app/Contents/Info.plist" "$localizations" <<'PY'
import sys
path, langs = sys.argv[1], sys.argv[2]
text = open(path).read().replace("    <!-- __LOCALIZATIONS__ -->\n", langs)
open(path, "w").write(text)
PY
plutil -lint "$app/Contents/Info.plist"

codesign --force --deep --sign - "$app"

(cd "$root/build" && ditto -c -k --keepParent Elsewhen.app Elsewhen.zip)
echo "built $app"
