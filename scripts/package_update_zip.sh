#!/bin/bash
# Shared by release preparation, local reproduction and regression tests. No keys/network.
set -euo pipefail
[[ $# == 2 && -d "$1" ]] || { echo 'Kullanım: scripts/package_update_zip.sh <AtışPress.app> <zip>' >&2; exit 1; }
/usr/bin/ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent "$1" "$2"
