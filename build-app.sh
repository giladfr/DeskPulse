#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
bundle_identifier=${DESKPULSE_BUNDLE_ID:-com.giladfride.DeskPulse}
default_signing_identity="-"
available_identities=$(security find-identity -v -p codesigning)
# Prefer a local "DeskPulse Local Signing" identity; the pre-rename name is still honored.
for candidate in "DeskPulse Local Signing" "OfficeDashboard Local Signing"; do
  if print -r -- "$available_identities" | grep -Fq "\"$candidate\""; then
    default_signing_identity=$candidate
    break
  fi
done
signing_identity=${DESKPULSE_SIGNING_IDENTITY:-$default_signing_identity}
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/DeskPulse.app"
installed_app="/Applications/DeskPulse.app"
legacy_installed_app="/Applications/OfficeDashboard.app"

cd "$project_dir"
swift build -c release
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/DeskPulse" "$app_dir/Contents/MacOS/DeskPulse"
cp "Packaging/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app_dir/Contents/Info.plist"
cp "Packaging/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
if [[ ! -x "Tools/bin/ShazamRecognizer" ]]; then
  echo "Building the optional local song-recognition helper..."
  "Tools/build-shazam-helper.sh"
fi
mkdir -p "$app_dir/Contents/Helpers"
cp "Tools/bin/ShazamRecognizer" "$app_dir/Contents/Helpers/ShazamRecognizer"
cp "Tools/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"
if [[ -d ".build/release/DeskPulse_DeskPulse.bundle" ]]; then
  cp -R ".build/release/DeskPulse_DeskPulse.bundle" "$app_dir/Contents/Resources/"
fi
xattr -cr "$app_dir"
# Finder may reapply these cloud/Finder attributes to an app that was opened before.
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
resource_bundle="$app_dir/Contents/Resources/DeskPulse_DeskPulse.bundle"
if [[ -d "$resource_bundle" ]]; then
  xattr -d com.apple.FinderInfo "$resource_bundle" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$resource_bundle" 2>/dev/null || true
fi
if [[ "$signing_identity" != "-" ]] && ! print -r -- "$available_identities" | grep -Fq "\"$signing_identity\""; then
  echo "Missing local signing identity: $signing_identity" >&2
  exit 1
fi
codesign --force --deep --timestamp=none --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"

if [[ -e "$installed_app" ]]; then
  previous_app="$HOME/.Trash/DeskPulse-previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$installed_app" "$previous_app"
fi
if [[ -e "$legacy_installed_app" ]]; then
  previous_legacy_app="$HOME/.Trash/OfficeDashboard-renamed-$(date +%Y%m%d-%H%M%S).app"
  mv "$legacy_installed_app" "$previous_legacy_app"
fi
ditto "$app_dir" "$installed_app"
codesign --verify --deep --strict "$installed_app"
echo "$installed_app"
