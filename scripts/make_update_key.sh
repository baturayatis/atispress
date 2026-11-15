#!/bin/bash
# Private key material exists only in this process and the macOS Keychain.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS gerekir.' >&2; exit 1; }
bin_dir="$(mktemp -d)"
trap 'rm -rf "$bin_dir"' EXIT
xcrun swiftc "$repo_dir/Sources/AtisPressApp/UpdateManifest.swift" "$repo_dir/Sources/AtisPressApp/UpdateArchive.swift" "$repo_dir/Sources/AtisPressApp/UpdateArchiveAudit.swift" "$repo_dir/Sources/AtisPressApp/UpdateInstaller.swift" "$repo_dir/scripts/ReleaseTool/main.swift" -o "$bin_dir/release-tool"
"$bin_dir/release-tool" keygen "$repo_dir"
