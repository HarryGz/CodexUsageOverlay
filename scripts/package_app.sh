#!/bin/bash
set -euo pipefail

[[ $# -eq 0 ]] || { echo "Usage: ./scripts/package_app.sh" >&2; exit 2; }
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$project_root"
swift test
swift build -c release --arch arm64
binary_directory="$(swift build -c release --arch arm64 --show-bin-path)"
executable="$binary_directory/CodexUsageOverlay"
[[ -f "$executable" && -x "$executable" ]] || { echo "Release executable is missing." >&2; exit 1; }
/usr/bin/plutil -lint Resources/Info.plist

distribution="$project_root/dist"
app="$distribution/CodexUsageOverlay.app"
[[ ! -L "$distribution" && ! -L "$app" ]] || { echo "Refusing symlinked package destination." >&2; exit 1; }
mkdir -p -- "$distribution"
staging="$(mktemp -d "$distribution/.package.XXXXXX")"
cleanup() {
    case "$staging" in "$distribution"/.package.*) /bin/rm -rf -- "$staging" ;; esac
}
trap cleanup EXIT
staged_app="$staging/CodexUsageOverlay.app"
mkdir -p -- "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
/bin/cp -- "$executable" "$staged_app/Contents/MacOS/CodexUsageOverlay"
/bin/cp -- Resources/Info.plist "$staged_app/Contents/Info.plist"
/bin/cp -- LICENSE THIRD_PARTY_NOTICES.md "$staged_app/Contents/Resources/"
/usr/bin/codesign --force --deep --sign - "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_app"
# Replace only the generated bundle after the staged artifact has passed signing.
[[ "$app" == "$project_root/dist/CodexUsageOverlay.app" && ! -L "$app" ]] || exit 1
if [[ -e "$app" ]]; then /bin/rm -rf -- "$app"; fi
/bin/mv -- "$staged_app" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
echo "Packaged: $app"
