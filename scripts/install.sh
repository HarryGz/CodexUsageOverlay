#!/bin/bash
set -euo pipefail

[[ $# -eq 0 ]] || { echo "Usage: ./scripts/install.sh" >&2; exit 2; }
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_app="$project_root/dist/CodexUsageOverlay.app"
install_home="${HOME:?HOME must identify your home directory}"
[[ "$install_home" == /* && "$install_home" != / && -d "$install_home" && ! -L "$install_home" ]] || exit 1
[[ "$(cd -- "$install_home" && pwd -P)" == "$install_home" ]] || { echo "Home must be an explicit canonical path." >&2; exit 1; }
applications="$install_home/Applications"
installed_app="$install_home/Applications/CodexUsageOverlay.app"
[[ ! -L "$applications" && ! -L "$installed_app" && ! -L "$project_root/dist" && ! -L "$source_app" ]] || {
    echo "Refusing symlinked application paths." >&2; exit 1;
}
[[ "$source_app" == "$project_root/dist/CodexUsageOverlay.app" && -d "$source_app" && -x "$source_app/Contents/MacOS/CodexUsageOverlay" ]] || {
    echo "Run ./scripts/package_app.sh first." >&2; exit 1;
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == local.codex-usage-overlay ]] || exit 1
/usr/bin/codesign --verify --deep --strict --verbose=2 "$source_app"
[[ "$installed_app" == "$install_home/Applications/CodexUsageOverlay.app" ]] || exit 1
if [[ -e "$installed_app" ]]; then
    [[ -d "$installed_app" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")" == local.codex-usage-overlay ]] || {
        echo "Destination is not the expected app; refusing replacement." >&2; exit 1;
    }
    /bin/rm -rf -- "$installed_app"
fi
mkdir -p -- "$applications"
/usr/bin/ditto "$source_app" "$installed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$installed_app"
echo "Installed CodexUsageOverlay.app in ~/Applications. Open it manually."
