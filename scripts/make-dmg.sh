#!/bin/bash
# Build a Release Crab.app and pack it into build/Crab-<version>-<sha>.dmg.
#
# Adapted from Saddle's scripts/make-dmg.sh. Crab has no File Provider
# extension, so the appex, app-group, and keychain-group checks are gone.
# The app embeds the crab CLI at Contents/Helpers/crab. CrabKit is a static
# framework (linked in, not a signed extension); any framework the build
# actually embeds is still checked.
#
# project.yml is the source of truth (xcodegen regenerates Crab.xcodeproj
# when it is installed). Signing settings in the project are left alone:
# local builds stay ad-hoc (CODE_SIGN_IDENTITY "-", empty DEVELOPMENT_TEAM).
# This script only overrides signing for the archive it creates. It uses a
# Developer ID Application certificate when one is installed (hardened
# runtime, notarize only if notarytool already has credentials). Otherwise
# it signs with Apple Development. It never prompts for or stores an Apple ID.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Crab.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING="$BUILD_DIR/staging"
DERIVED="$BUILD_DIR/DerivedData"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
SOURCE_ENTITLEMENTS="$ROOT/Crab/Crab.entitlements"

mkdir -p "$BUILD_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  echo "Regenerating Crab.xcodeproj from project.yml…"
  xcodegen
else
  echo "xcodegen is not installed; using the committed Crab.xcodeproj."
fi

# First DEVELOPMENT_TEAM in project.yml. Empty means the project stays ad-hoc
# and this script takes the team from the signing certificate it selects.
project_team() {
  local line value
  line=$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM:' "$ROOT/project.yml" | head -n 1 || true)
  value=$(printf '%s\n' "$line" | sed -E \
    's/^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*//; s/[[:space:]]+#.*//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//')
  printf '%s' "$value"
}

identity_team() {
  local name="$1"
  security find-certificate -c "$name" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/.*OU=\([^,]*\).*/\1/p' \
    | head -n 1
}

# Print identities whose common name starts with $1.
# When project.yml names a team, keep only that team (OU, or the team id in
# the certificate name). Developer ID names embed the team id; Apple
# Development names embed a certificate id, so the OU is the reliable check.
matching_identities() {
  local prefix="$1"
  local line name team
  while IFS= read -r line; do
    name=$(printf '%s\n' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')
    [[ -n "$name" ]] || continue
    [[ "$name" == "$prefix"* ]] || continue
    if [[ -n "$PROJECT_TEAM" ]]; then
      team="$(identity_team "$name" || true)"
      if [[ "$team" == "$PROJECT_TEAM" || "$name" == *"($PROJECT_TEAM)"* ]]; then
        printf '%s\n' "$name"
      fi
    else
      printf '%s\n' "$name"
    fi
  done < <(security find-identity -v -p codesigning)
  return 0
}

PROJECT_TEAM="$(project_team)"
echo "Project DEVELOPMENT_TEAM: ${PROJECT_TEAM:-<empty>}"

SIGN_KIND=""
IDENTITIES=""
if IDENTITIES="$(matching_identities "Developer ID Application")" && [[ -n "$IDENTITIES" ]]; then
  SIGN_KIND="developer-id"
elif IDENTITIES="$(matching_identities "Apple Development")" && [[ -n "$IDENTITIES" ]]; then
  SIGN_KIND="development"
else
  echo "No Developer ID Application or Apple Development identity for team ${PROJECT_TEAM:-<any>}." >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

COUNT=$(printf '%s\n' "$IDENTITIES" | grep -c .)
if [[ "$COUNT" -gt 1 ]]; then
  echo "Multiple ${SIGN_KIND} identities match. Refusing to guess:" >&2
  printf '%s\n' "$IDENTITIES" >&2
  exit 1
fi
IDENTITY="$IDENTITIES"
TEAM_ID="$(identity_team "$IDENTITY" || true)"
if [[ -z "$TEAM_ID" ]]; then
  echo "Could not read a team id from certificate: $IDENTITY" >&2
  exit 1
fi
if [[ -n "$PROJECT_TEAM" && "$TEAM_ID" != "$PROJECT_TEAM" ]]; then
  echo "Certificate team ${TEAM_ID} does not match project team ${PROJECT_TEAM}." >&2
  exit 1
fi

echo "Signing identity ($SIGN_KIND): $IDENTITY"
echo "Certificate team: $TEAM_ID"

rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGING"
mkdir -p "$BUILD_DIR"

# Command-line settings override the project's ad-hoc identity for this
# archive only. project.yml and the xcodeproj are not edited.
# Automatic signing accepts the generic identity ("Apple Development" or
# "Developer ID Application"), not the full certificate common name. The
# full name is still what we require on the signed app and DMG.
if [[ "$SIGN_KIND" == "developer-id" ]]; then
  SIGN_IDENTITY_SETTING="Developer ID Application"
else
  SIGN_IDENTITY_SETTING="Apple Development"
fi
# A generic macOS archive builds every architecture. Current main does not
# compile the x86_64 slice: CrabKit calls VZMac* types that exist only in the
# arm64 Virtualization SDK. This script does not patch that. It archives the
# host architecture so the DMG matches the Mac it was built on.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "Unexpected machine architecture: ${HOST_ARCH}" >&2
    exit 1
    ;;
esac
echo "Archiving host architecture: ${HOST_ARCH}"
ARCHIVE_ARGS=(
  -project "$ROOT/Crab.xcodeproj"
  -scheme Crab
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE"
  -derivedDataPath "$DERIVED"
  -allowProvisioningUpdates
  "ARCHS=${HOST_ARCH}"
  ONLY_ACTIVE_ARCH=YES
  CODE_SIGN_STYLE=Automatic
  "CODE_SIGN_IDENTITY=$SIGN_IDENTITY_SETTING"
  "DEVELOPMENT_TEAM=$TEAM_ID"
)
if [[ "$SIGN_KIND" == "developer-id" ]]; then
  ARCHIVE_ARGS+=(ENABLE_HARDENED_RUNTIME=YES)
else
  ARCHIVE_ARGS+=(ENABLE_HARDENED_RUNTIME=NO)
fi

echo "Archiving Release Crab…"
xcodebuild archive "${ARCHIVE_ARGS[@]}" 2>&1 | tee "$BUILD_DIR/archive.log"

# The crab tool installs to /usr/local/bin and is also copied into
# Crab.app/Contents/Helpers. That second product makes Xcode treat the
# archive as a generic product archive, so it omits ApplicationProperties
# and every Mac export method refuses it. The DMG only ships the app.
prepare_archive_for_export() {
  local products="$ARCHIVE/Products"
  local app rel bid ver buildn
  if [[ -d "$products/usr" ]]; then
    echo "Removing the standalone crab product from the archive."
    rm -rf "$products/usr"
  fi
  if /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$ARCHIVE/Info.plist" >/dev/null 2>&1; then
    return 0
  fi
  app="$(find_app "$products" || true)"
  if [[ -z "$app" ]]; then
    echo "Archive has no Crab.app to describe." >&2
    exit 1
  fi
  rel="Applications/$(basename "$app")"
  bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  buildn="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties dict' "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:ApplicationPath string ${rel}" "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:Architectures array' "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:Architectures:0 string ${HOST_ARCH}" "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:CFBundleIdentifier string ${bid}" "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:CFBundleShortVersionString string ${ver}" "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:CFBundleVersion string ${buildn}" "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:SigningIdentity string ${IDENTITY}" "$ARCHIVE/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:Team string ${TEAM_ID}" "$ARCHIVE/Info.plist"
  echo "Wrote ApplicationProperties so Xcode can export the Mac app."
}

write_export_plist() {
  local method="$1"
  cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>method</key>
	<string>${method}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
</dict>
</plist>
EOF
}

export_archive() {
  local method="$1"
  echo "Exporting archive with method ${method}…"
  write_export_plist "$method"
  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    2>&1 | tee "$BUILD_DIR/export-${method}.log"
}

find_app() {
  local root="$1"
  local candidate
  while IFS= read -r candidate; do
    if [[ "$(basename "$candidate")" == "Crab.app" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$root" -maxdepth 4 -type d -name 'Crab.app' 2>/dev/null || true)
  return 1
}

prepare_archive_for_export

exported=0
if [[ "$SIGN_KIND" == "developer-id" ]]; then
  if export_archive developer-id; then
    exported=1
  fi
else
  # Xcode 27 prefers `debugging`. `development` still works and is deprecated.
  if export_archive debugging; then
    exported=1
  elif export_archive development; then
    exported=1
  elif export_archive mac-application; then
    exported=1
  fi
fi

APP_SRC=""
if [[ "$exported" -eq 1 ]]; then
  APP_SRC="$(find_app "$EXPORT_DIR" || true)"
fi
if [[ -z "$APP_SRC" ]]; then
  echo "Export did not produce an app. Using the archive product."
  APP_SRC="$(find_app "$ARCHIVE/Products" || true)"
fi
if [[ -z "$APP_SRC" || ! -d "$APP_SRC" ]]; then
  echo "No Crab.app was produced." >&2
  exit 1
fi
echo "App source: $APP_SRC"

mkdir -p "$STAGING"
ditto "$APP_SRC" "$STAGING/Crab.app"
ln -s /Applications "$STAGING/Applications"

APP="$STAGING/Crab.app"
HELPER="$APP/Contents/Helpers/crab"
if [[ ! -f "$HELPER" ]]; then
  echo "crab is not embedded at Contents/Helpers/crab." >&2
  find "$APP" -type f >&2 || true
  exit 1
fi

require_identity() {
  local target="$1"
  local label="$2"
  local sig
  # Authority lines are only printed at verbose level 3 and above.
  sig=$(codesign -dvvv "$target" 2>&1 || true)
  printf '%s\n' "$sig" > "$BUILD_DIR/${label}-codesign.txt"
  if printf '%s\n' "$sig" | grep -q 'Signature=adhoc'; then
    echo "${label} is ad-hoc signed; expected ${IDENTITY}." >&2
    exit 1
  fi
  if ! printf '%s\n' "$sig" | grep -F -q "Authority=${IDENTITY}"; then
    echo "${label} is not signed by ${IDENTITY}." >&2
    printf '%s\n' "$sig" >&2
    exit 1
  fi
}

echo "Verifying code signature…"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tee "$BUILD_DIR/codesign-verify.txt"
require_identity "$APP" "app"
require_identity "$HELPER" "helper"

# `-d --entitlements -` is the readable dump. `:-` is XML for PlistBuddy.
codesign -d --entitlements - "$APP" > "$BUILD_DIR/app-entitlements.txt" 2>> "$BUILD_DIR/app-codesign.txt"
codesign -d --entitlements :- "$APP" > "$BUILD_DIR/app-entitlements.plist"
codesign -d --entitlements - "$HELPER" > "$BUILD_DIR/helper-entitlements.txt" 2>> "$BUILD_DIR/helper-codesign.txt"
codesign -d --entitlements :- "$HELPER" > "$BUILD_DIR/helper-entitlements.plist"

python3 - "$SOURCE_ENTITLEMENTS" "$BUILD_DIR/app-entitlements.plist" "Crab.app" <<'PY'
import plistlib, sys
src_path, signed_path, label = sys.argv[1:]
with open(src_path, "rb") as handle:
    source = plistlib.load(handle)
signed_bytes = open(signed_path, "rb").read()
if not signed_bytes.strip():
    sys.exit(f"{label}: codesign returned no entitlements")
signed = plistlib.loads(signed_bytes)
interesting = [
    "com.apple.security.virtualization",
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.get-task-allow",
]
print(f"Entitlement check ({label}):")
for key in interesting:
    print(f"  {key}: source={source.get(key, 'absent')} signed={signed.get(key, 'absent')}")
print("  signed keys: " + (", ".join(sorted(signed)) or "(none)"))
errors = []
if signed.get("com.apple.security.virtualization") is not True:
    errors.append("com.apple.security.virtualization is not true")
for key, value in source.items():
    if signed.get(key) != value:
        errors.append(f"{key} signed={signed.get(key)!r} source={value!r}")
if signed.get("com.apple.security.app-sandbox") is True and source.get("com.apple.security.app-sandbox") is not True:
    errors.append("app sandbox was injected but Crab.entitlements does not declare it")
if errors:
    print(f"{label} entitlement mismatch:", file=sys.stderr)
    for item in errors:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY
python3 - "$SOURCE_ENTITLEMENTS" "$BUILD_DIR/helper-entitlements.plist" "Contents/Helpers/crab" <<'PY'
import plistlib, sys
src_path, signed_path, label = sys.argv[1:]
with open(src_path, "rb") as handle:
    source = plistlib.load(handle)
signed_bytes = open(signed_path, "rb").read()
if not signed_bytes.strip():
    sys.exit(f"{label}: codesign returned no entitlements")
signed = plistlib.loads(signed_bytes)
interesting = [
    "com.apple.security.virtualization",
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.get-task-allow",
]
print(f"Entitlement check ({label}):")
for key in interesting:
    print(f"  {key}: source={source.get(key, 'absent')} signed={signed.get(key, 'absent')}")
print("  signed keys: " + (", ".join(sorted(signed)) or "(none)"))
errors = []
if signed.get("com.apple.security.virtualization") is not True:
    errors.append("com.apple.security.virtualization is not true")
for key, value in source.items():
    if signed.get(key) != value:
        errors.append(f"{key} signed={signed.get(key)!r} source={value!r}")
if signed.get("com.apple.security.app-sandbox") is True and source.get("com.apple.security.app-sandbox") is not True:
    errors.append("app sandbox was injected but Crab.entitlements does not declare it")
if errors:
    print(f"{label} entitlement mismatch:", file=sys.stderr)
    for item in errors:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY

# Static CrabKit is linked in. If a build also copies a framework or appex,
# record its signature and entitlements. Virtualization is required only when
# that binary's entitlements mention it (the app and helper already must).
shopt -s nullglob
embedded=()
for framework in "$APP/Contents/Frameworks/"*.framework; do
  embedded+=("$framework")
done
for appex in "$APP/Contents/PlugIns/"*.appex; do
  embedded+=("$appex")
done
shopt -u nullglob

if [[ "${#embedded[@]}" -eq 0 ]]; then
  echo "No embedded frameworks or app extensions. CrabKit is a static framework and is linked into Crab and crab."
else
  index=0
  for item in "${embedded[@]}"; do
    index=$((index + 1))
    name="$(basename "$item")"
    echo "Embedded: $name"
    codesign --verify --strict --verbose=2 "$item" 2>&1 | tee "$BUILD_DIR/embedded-${index}-verify.txt"
    codesign -d --entitlements - "$item" > "$BUILD_DIR/embedded-${index}-entitlements.txt" 2> "$BUILD_DIR/embedded-${index}-codesign.txt" || true
    codesign -d --entitlements :- "$item" > "$BUILD_DIR/embedded-${index}-entitlements.plist" 2>/dev/null || true
    python3 - "$BUILD_DIR/embedded-${index}-entitlements.plist" "$name" <<'PY'
import plistlib, sys
path, label = sys.argv[1:]
raw = open(path, "rb").read()
if not raw.strip():
    print(f"  {label}: no entitlements (expected for a static framework without CODE_SIGN_ENTITLEMENTS)")
    sys.exit(0)
signed = plistlib.loads(raw)
print(f"  {label} signed keys: " + (", ".join(sorted(signed)) or "(none)"))
virt = signed.get("com.apple.security.virtualization", "absent")
print(f"  com.apple.security.virtualization: {virt}")
if "com.apple.security.virtualization" in signed and virt is not True:
    sys.exit(f"{label}: com.apple.security.virtualization is present but not true")
sandbox = signed.get("com.apple.security.app-sandbox", "absent")
print(f"  com.apple.security.app-sandbox: {sandbox}")
for key in ("com.apple.security.network.client", "com.apple.security.network.server"):
    print(f"  {key}: {signed.get(key, 'absent')}")
PY
  done
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
case "$VERSION" in
  *'$'*)
    echo "CFBundleShortVersionString was not resolved (${VERSION})." >&2
    exit 1
    ;;
esac
SHA="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
DMG="$BUILD_DIR/Crab-${VERSION}-${SHA}.dmg"

echo "Creating ${DMG}…"
COPYFILE_DISABLE=1 hdiutil create -volname Crab -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "Signing DMG…"
if [[ "$SIGN_KIND" == "developer-id" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
else
  codesign --sign "$IDENTITY" "$DMG"
fi
codesign --verify --verbose=2 "$DMG" 2>&1 | tee "$BUILD_DIR/dmg-codesign.txt"

ATTACH_PLIST="$BUILD_DIR/dmg-attach.plist"
if ! COPYFILE_DISABLE=1 hdiutil attach -nobrowse -readonly -plist "$DMG" > "$ATTACH_PLIST"; then
  echo "Could not mount ${DMG}." >&2
  exit 1
fi
MOUNT="$(python3 -c '
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    data = plistlib.load(handle)
for entity in data.get("system-entities", []):
    if "mount-point" in entity:
        print(entity["mount-point"])
        break
' "$ATTACH_PLIST")"
detach_dmg() {
  if [[ -n "${MOUNT:-}" ]]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
    MOUNT=""
  fi
}
if [[ -z "$MOUNT" || ! -d "$MOUNT/Crab.app" || ! -L "$MOUNT/Applications" ]]; then
  echo "Mounted DMG is missing Crab.app or the Applications symlink." >&2
  detach_dmg
  exit 1
fi
LINK_TARGET="$(readlink "$MOUNT/Applications")"
detach_dmg
if [[ "$LINK_TARGET" != "/Applications" ]]; then
  echo "Applications symlink points at ${LINK_TARGET}." >&2
  exit 1
fi
echo "DMG layout: Crab.app and a symlink to /Applications"

if [[ "$SIGN_KIND" == "developer-id" ]]; then
  if xcrun notarytool history >/dev/null 2>&1; then
    echo "Submitting DMG for notarization…"
    xcrun notarytool submit "$DMG" --wait 2>&1 | tee "$BUILD_DIR/notarize.log"
    xcrun stapler staple "$DMG"
  else
    echo "Notarization skipped: notarytool has no stored credentials."
  fi
else
  echo "Notarization skipped: signed with Apple Development, not Developer ID."
fi

echo "DMG ready: $DMG"
ls -lh "$DMG"
