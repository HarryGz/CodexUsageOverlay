#!/bin/bash
set -euo pipefail

[[ $# -eq 0 ]] || { echo "Usage: ./scripts/uninstall.sh" >&2; exit 2; }
install_home="${HOME:?HOME must identify your home directory}"
[[ "$install_home" == /* && "$install_home" != / && -d "$install_home" && ! -L "$install_home" ]] || exit 1
[[ "$(cd -- "$install_home" && pwd -P)" == "$install_home" ]] || { echo "Home must be an explicit canonical path." >&2; exit 1; }
applications="$install_home/Applications"
installed_app="$install_home/Applications/CodexUsageOverlay.app"
[[ ! -L "$applications" && ! -L "$installed_app" ]] || { echo "Refusing symlinked application paths." >&2; exit 1; }
[[ "$installed_app" == "$install_home/Applications/CodexUsageOverlay.app" ]] || exit 1
if [[ -e "$installed_app" ]]; then
    [[ -d "$installed_app" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")" == local.codex-usage-overlay ]] || {
        echo "Destination is not the expected app; refusing removal." >&2; exit 1;
    }
    /bin/rm -rf -- "$installed_app"
    echo "Removed only ~/Applications/CodexUsageOverlay.app. Reinstall to restore the app."
else
    echo "CodexUsageOverlay.app is not installed in ~/Applications."
fi
echo "UserDefaults and Accessibility authorization are not removed automatically."
