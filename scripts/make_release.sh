#!/bin/bash
# Builds/signs locally. Never uploads, pushes, or contacts the notary service.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# == 1 && "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Kullanım: scripts/make_release.sh <version>' >&2; exit 1; }
version="$1"
source_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)
[[ "$version" == "$source_version" ]] || { echo 'Önce plist ve AppHelp sürüm/build değerlerini güncelleyin.' >&2; exit 1; }
bin_dir="$(mktemp -d)"
trap 'rm -rf "$bin_dir"' EXIT
xcrun swiftc Sources/AtisPressApp/UpdateManifest.swift Sources/AtisPressApp/UpdateArchive.swift Sources/AtisPressApp/UpdateArchiveAudit.swift Sources/AtisPressApp/UpdateInstaller.swift scripts/ReleaseTool/main.swift -o "$bin_dir/release-tool"
"$bin_dir/release-tool" check "$repo_dir"
./scripts/build_app.sh
# Explicitly clear credentials for this child: release preparation must stay offline.
env -u APPLE_ID -u TEAM_ID -u APP_PASSWORD ./scripts/make_dmg.sh --skip-build
zip_path="$repo_dir/dist/AtisPress-$version.zip"
./scripts/package_update_zip.sh 'dist/AtışPress.app' "$bin_dir/update.zip"
mv "$bin_dir/update.zip" "$zip_path"
"$bin_dir/release-tool" sign "$repo_dir" "$version" "$zip_path" "$repo_dir/dist/update.json"
"$bin_dir/release-tool" verify "$zip_path" "$repo_dir/dist/update.json" "$repo_dir/packaging/Info.plist"
printf '\nYüklemek için bu komutu kendiniz çalıştırın (henüz yüklenmedi):\n'
printf "gh release create 'v%s' 'dist/AtisPress-%s.dmg' 'dist/AtisPress-%s.zip' 'dist/update.json' --title 'AtışPress %s' --notes-file '%s'\n" "$version" "$version" "$version" "$version" "$(if [[ -f RELEASE_NOTES.md ]]; then echo RELEASE_NOTES.md; else echo CHANGELOG.md; fi)"
