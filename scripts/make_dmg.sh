#!/bin/bash
# Package a universal app; optionally sign/notarize when credentials are available.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "DMG oluşturmak için macOS ve Xcode komut satırı araçları gerekir." >&2
    exit 1
fi
skip_build=0
for argument in "$@"; do
    case "$argument" in
        --skip-build) skip_build=1 ;;
        *) echo "Kullanım: $0 [--skip-build]" >&2; exit 1 ;;
    esac
done
if [[ "$skip_build" == 0 ]]; then ./scripts/build_app.sh; fi

app_path="$repo_dir/dist/AtışPress.app"
[[ -d "$app_path" ]] || { echo "Önce scripts/build_app.sh çalıştırın." >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
# Keep the downloadable filename ASCII and disallow path components.
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Geçersiz uygulama sürümü: $version" >&2; exit 1; }
dmg_path="$repo_dir/dist/AtisPress-$version.dmg"
stage_dir="$(mktemp -d "$repo_dir/dist/.make-dmg.XXXXXX")"
mount_dir="$stage_dir/mount"
mount_active=0
cleanup() {
    local result=$?
    if [[ "$mount_active" == 1 ]]; then
        if ! hdiutil detach "$mount_dir"; then
            echo "Birim ayrılamadı; geçici klasör korundu: $stage_dir" >&2
            exit 1
        fi
    fi
    rm -rf "$stage_dir"
    exit "$result"
}
trap cleanup EXIT
mkdir -p "$stage_dir/content" "$mount_dir"
bundle="$stage_dir/content/AtışPress.app"
ditto "$app_path" "$bundle"
ln -s /Applications "$stage_dir/content/Applications"
for arch in arm64 x86_64; do
    xcrun lipo "$bundle/Contents/MacOS/AtisPressApp" -verify_arch "$arch"
done
xcrun lipo -info "$bundle/Contents/MacOS/AtisPressApp"
codesign --verify --deep --strict --verbose=2 "$bundle"

# Never print credentials. Select a valid Developer ID Application identity in TEAM_ID.
signing_identity=""
if [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
    signing_identity=$(security find-identity -v -p codesigning | awk -v team="$TEAM_ID" '
        /"Developer ID Application: / && index($0, "(" team ")\"") { print $2; exit }')
    if [[ -z "$signing_identity" ]]; then
        echo "Noter onayı atlandı: TEAM_ID için geçerli Developer ID Application kimliği bulunamadı; ad-hoc imza korunuyor."
    fi
else
    echo "Noter onayı atlandı: APPLE_ID, TEAM_ID ve APP_PASSWORD birlikte ayarlanmalı; ad-hoc imza korunuyor."
fi
if [[ -n "$signing_identity" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$bundle"
    codesign --verify --deep --strict --verbose=2 "$bundle"
fi

staged_dmg="$stage_dir/AtisPress-$version.dmg"
hdiutil create -volname "AtışPress" -fs HFS+ -srcfolder "$stage_dir/content" -format UDZO "$staged_dmg"
if [[ -n "$signing_identity" ]]; then
    codesign --timestamp --sign "$signing_identity" "$staged_dmg"
    # Require explicit acceptance before stapling or replacing the previous image.
    xcrun notarytool submit "$staged_dmg" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait --output-format plist > "$stage_dir/notary.plist"
    status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$stage_dir/notary.plist")
    [[ "$status" == Accepted ]] || { echo "Noter onayı başarısız: $status" >&2; exit 1; }
    xcrun stapler staple "$staged_dmg"
    xcrun stapler validate "$staged_dmg"
fi
hdiutil verify "$staged_dmg"
hdiutil attach "$staged_dmg" -readonly -nobrowse -mountpoint "$mount_dir"
mount_active=1
[[ -d "$mount_dir/AtışPress.app" ]]
[[ -L "$mount_dir/Applications" && "$(readlink "$mount_dir/Applications")" == /Applications ]]
for arch in arm64 x86_64; do
    xcrun lipo "$mount_dir/AtışPress.app/Contents/MacOS/AtisPressApp" -verify_arch "$arch"
done
codesign --verify --deep --strict --verbose=2 "$mount_dir/AtışPress.app"
hdiutil detach "$mount_dir"
mount_active=0
# Replace only after checksum verification and the requested checks succeed.
mv -f "$staged_dmg" "$dmg_path"
printf '\nDMG hazır: %s\n' "$dmg_path"
shasum -a 256 "$dmg_path"
