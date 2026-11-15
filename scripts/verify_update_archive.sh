#!/bin/bash
# One offline command: supplied ZIP, or rebuild and package the current universal app.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -le 1 ]] || { echo 'Kullanım: scripts/verify_update_archive.sh [zip]' >&2; exit 1; }
bin_dir="$(mktemp -d)"
trap 'rm -rf "$bin_dir"' EXIT
if [[ $# == 1 ]]; then
    zip_path="$1"
else
    ./scripts/build_app.sh
    zip_path="$bin_dir/update.zip"
    ./scripts/package_update_zip.sh 'dist/AtışPress.app' "$zip_path"
fi
xcrun swiftc -O Sources/AtisPressApp/UpdateManifest.swift Sources/AtisPressApp/UpdateArchive.swift Sources/AtisPressApp/UpdateArchiveAudit.swift Sources/AtisPressApp/UpdateInstaller.swift scripts/ReleaseTool/main.swift -o "$bin_dir/release-tool"
"$bin_dir/release-tool" inspect "$zip_path"
