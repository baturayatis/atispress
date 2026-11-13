#!/bin/bash
# Build a universal, ad-hoc-signed macOS bundle. Extra arguments go to SwiftPM.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "AtışPress requires macOS 14+ and Xcode command-line tools." >&2
    exit 1
fi

swift build --disable-sandbox --configuration release --arch arm64 --arch x86_64 -debug-info-format none --product AtisPressApp "$@"
bin_dir="$(swift build --disable-sandbox --configuration release --arch arm64 --arch x86_64 -debug-info-format none --show-bin-path "$@")"
dist_dir="$repo_dir/dist"
app_path="$dist_dir/AtışPress.app"
mkdir -p "$dist_dir"
stage_dir="$(mktemp -d "$dist_dir/.build-app.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
bundle="$stage_dir/AtışPress.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$bin_dir/AtisPressApp" "$bundle/Contents/MacOS/AtisPressApp"
for arch in arm64 x86_64; do
    xcrun lipo "$bundle/Contents/MacOS/AtisPressApp" -verify_arch "$arch"
done
xcrun lipo -info "$bundle/Contents/MacOS/AtisPressApp"
cp packaging/Info.plist "$bundle/Contents/Info.plist"
printf 'APPL????' > "$bundle/Contents/PkgInfo"

if [[ -f packaging/AppIcon.icns ]]; then
    cp packaging/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
else
    xcrun swift scripts/generate_app_icon.swift "$bundle/Contents/Resources/AppIcon.icns"
fi
plutil -lint "$bundle/Contents/Info.plist"
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"

# Replace only a successfully built and verified bundle; leave source projects alone.
rm -rf "$app_path"
mv "$bundle" "$app_path"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$lsregister" ]] && ! "$lsregister" -f "$app_path"; then
    echo "LaunchServices registration unavailable. Move the app to /Applications and open it once." >&2
fi
printf '\nBuilt: %s\n' "$app_path"
printf 'Open with: open "%s"\n' "$app_path"
