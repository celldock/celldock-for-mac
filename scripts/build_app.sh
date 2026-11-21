#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
mkdir -p "$ROOT/.build/home"
export HOME="${HOME:-$ROOT/.build/home}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$ROOT/.build/caches}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"
VERSION="${CELLDOCK_VERSION:-${MAVO_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")}}"
SOURCE_BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$ROOT/Resources/Info.plist")"
AUTO_INCREMENT_BUILD_VERSION=false
if [[ -n "${CELLDOCK_BUILD_VERSION:-}" ]]; then
  BUILD_VERSION="$CELLDOCK_BUILD_VERSION"
else
  [[ "$SOURCE_BUILD_VERSION" == <-> ]] || {
    print -u2 "Cannot automatically increment non-integer CellDock build version: $SOURCE_BUILD_VERSION"
    exit 1
  }
  BUILD_VERSION="$((SOURCE_BUILD_VERSION + 1))"
  AUTO_INCREMENT_BUILD_VERSION=true
fi
[[ -n "$VERSION" && "$VERSION" != */* ]] || {
  print -u2 "Invalid CellDock version: $VERSION"
  exit 1
}
[[ "$BUILD_VERSION" == <->(|.<->)(|.<->) ]] || {
  print -u2 "Invalid CellDock build version: $BUILD_VERSION"
  exit 1
}
SIGNING_MODE="${CELLDOCK_SIGNING_MODE:-release}"
case "$SIGNING_MODE" in
  release|development|community) ;;
  *)
    print -u2 "Invalid CellDock signing mode: $SIGNING_MODE"
    print -u2 "Use release, development, or community."
    exit 1
    ;;
esac
SIGN_IDENTITY="${CELLDOCK_CODESIGN_IDENTITY:-${MAVO_CODESIGN_IDENTITY:-}}"
if [[ -z "$SIGN_IDENTITY" && "$SIGNING_MODE" != community ]]; then
  SIGN_IDENTITY="$(
  security find-identity -v -p codesigning |
    awk -F'"' -v mode="$SIGNING_MODE" '
      mode == "release" && /"Developer ID Application:/ { print $2; exit }
      mode == "development" && /"Apple Development:/ { print $2; exit }
    '
  )"
fi
[[ -n "$SIGN_IDENTITY" ]] || {
  print -u2 "No compatible $SIGNING_MODE signing identity is available."
  if [[ "$SIGNING_MODE" == community ]]; then
    print -u2 "Community archives require CELLDOCK_CODESIGN_IDENTITY."
  else
    print -u2 "Set CELLDOCK_CODESIGN_IDENTITY to a stable code-signing identity."
  fi
  exit 1
}
SIGN_IDENTITY_RECORD="$({ security find-identity -v -p codesigning || true; } | grep -F "$SIGN_IDENTITY" | head -n 1 || true)"
[[ -n "$SIGN_IDENTITY_RECORD" && "$SIGN_IDENTITY" != "-" ]] || {
  print -u2 "CellDock archives require a certificate-backed code-signing identity."
  print -u2 "Ad-hoc signing is not allowed because it breaks signer pinning and Keychain continuity."
  exit 1
}
SIGN_CERT_SHA1="$(print -r -- "$SIGN_IDENTITY_RECORD" | awk '{ print $2; exit }')"
[[ ${#SIGN_CERT_SHA1} -eq 40 && "$SIGN_CERT_SHA1" != *[^[:xdigit:]]* ]] || {
  print -u2 "Could not resolve the signing certificate SHA-1 fingerprint."
  exit 1
}
APP_REQUIREMENT_OPTIONS=()
HELPER_REQUIREMENT_OPTIONS=()
if [[ "$SIGNING_MODE" == release ]]; then
  [[ "$SIGN_IDENTITY_RECORD" == *'"Developer ID Application:'* ]] || {
    print -u2 "CellDock release archives must use a Developer ID Application identity."
    exit 1
  }
  ARCHIVE_SUFFIX=""
  CODESIGN_OPTIONS=(--options runtime --timestamp)
elif [[ "$SIGNING_MODE" == development ]]; then
  [[ "$SIGN_IDENTITY_RECORD" == *'"Apple Development:'* ]] || {
    print -u2 "CellDock development archives must use a stable Apple Development identity."
    print -u2 "Ad-hoc signing is not allowed because it would break Keychain access."
    exit 1
  }
  ARCHIVE_SUFFIX="-development"
  CODESIGN_OPTIONS=(--timestamp=none)
else
  ARCHIVE_SUFFIX="-community-unnotarized"
  CODESIGN_OPTIONS=(--options runtime --timestamp=none)
  APP_REQUIREMENT_OPTIONS=(
    --requirements
    "=designated => identifier \"app.celldock.mac\" and certificate leaf = H\"$SIGN_CERT_SHA1\""
  )
  HELPER_REQUIREMENT_OPTIONS=(
    --requirements
    "=designated => identifier \"app.celldock.mac.network.helper\" and certificate leaf = H\"$SIGN_CERT_SHA1\""
  )
fi
OUTPUT_DIR="$ROOT/outputs"
APP="$OUTPUT_DIR/CellDock.app"
ARCHIVE_ARCH="universal"
BUILD_ARCH_OPTIONS=(--arch arm64 --arch x86_64)
ZIP="$OUTPUT_DIR/CellDock-$VERSION-$ARCHIVE_ARCH$ARCHIVE_SUFFIX.zip"
PUBLISH_ZIP="$OUTPUT_DIR/.CellDock-$VERSION-$ARCHIVE_ARCH$ARCHIVE_SUFFIX.$$.zip"
STAGE_DIR="$(mktemp -d /tmp/CellDock-build.XXXXXX)"
STAGE_PACKAGE_DIR="$STAGE_DIR/package"
STAGE_APP="$STAGE_PACKAGE_DIR/CellDock.app"
SPARKLE_FRAMEWORK_SOURCE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_FRAMEWORK_RELATIVE="Contents/Frameworks/Sparkle.framework"
STAGE_ZIP="$STAGE_DIR/CellDock-$VERSION-$ARCHIVE_ARCH$ARCHIVE_SUFFIX.zip"
VERIFY_DIR="$STAGE_DIR/verify"
VERIFY_APP="$VERIFY_DIR/CellDock.app"
HELPER_RELATIVE="Contents/Library/PrivilegedHelperTools/CellDockNetworkHelper"
VOWIFI_RUNTIME_RELATIVE="Contents/Library/PrivilegedHelperTools/CellDockVoWiFiRuntime"
PLIST_RELATIVE="Contents/Library/LaunchDaemons/app.celldock.mac.network.helper.plist"
cleanup() {
  /bin/rm -rf -- "$STAGE_DIR"
  /bin/rm -f -- "$PUBLISH_ZIP"
}
trap cleanup EXIT

cd "$ROOT"
# macOS decides from the SDK version recorded in LC_BUILD_VERSION whether an
# app gets the current system appearance (window controls, materials). The
# SwiftPM link step records the deployment target as the SDK version, which
# puts the app in compatibility mode, so pass both values to the linker
# explicitly. The minimum comes from Info.plist (the single source of truth,
# matching Package.swift's macOS 14 platform); the SDK is the one installed.
DEPLOYMENT_TARGET="$(plutil -extract LSMinimumSystemVersion raw "$ROOT/Resources/Info.plist")"
[[ "$DEPLOYMENT_TARGET" == "14.0" ]] || {
  print -u2 "Resources/Info.plist LSMinimumSystemVersion ($DEPLOYMENT_TARGET) does not match the macOS 14 package platform."
  exit 1
}
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
[[ "$MACOS_SDK_VERSION" == <->.<->(|.<->) ]] || {
  print -u2 "Could not determine the installed macOS SDK version: $MACOS_SDK_VERSION"
  exit 1
}
LINKER_PLATFORM_OPTIONS=(
  -Xlinker -platform_version
  -Xlinker macos
  -Xlinker "$DEPLOYMENT_TARGET"
  -Xlinker "$MACOS_SDK_VERSION"
)
swift build --disable-sandbox -Xswiftc -disable-sandbox \
  -c release \
  "${BUILD_ARCH_OPTIONS[@]}" \
  "${LINKER_PLATFORM_OPTIONS[@]}"
BIN_DIR="$(swift build --disable-sandbox -Xswiftc -disable-sandbox \
  -c release \
  "${BUILD_ARCH_OPTIONS[@]}" \
  "${LINKER_PLATFORM_OPTIONS[@]}" \
  --show-bin-path)"

mkdir -p "$OUTPUT_DIR"
mkdir -p \
  "$STAGE_APP/Contents/MacOS" \
  "$STAGE_APP/Contents/Frameworks" \
  "$STAGE_APP/Contents/Resources" \
  "$STAGE_APP/Contents/Library/PrivilegedHelperTools" \
  "$STAGE_APP/Contents/Library/LaunchDaemons"
cp "$ROOT/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGE_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$STAGE_APP/Contents/Info.plist"
cp "$ROOT/Resources/CellDock.icns" "$STAGE_APP/Contents/Resources/CellDock.icns"
cp "$ROOT/Resources/sim.svg" "$STAGE_APP/Contents/Resources/sim.svg"
cp "$ROOT/Resources/sim1.svg" "$STAGE_APP/Contents/Resources/sim1.svg"
cp "$ROOT/Resources/celldock-module-vertical.svg" "$STAGE_APP/Contents/Resources/celldock-module-vertical.svg"
cp -R "$ROOT/Resources/Localization/"*.lproj "$STAGE_APP/Contents/Resources/"
mkdir -p "$STAGE_APP/Contents/Resources/Sounds"
cp "$ROOT/Resources/Sounds/"* "$STAGE_APP/Contents/Resources/Sounds/"
if [[ -d "$ROOT/Resources/ModuleVoice" ]]; then
  xcrun swift "$ROOT/scripts/build_module_voice_payload.swift" \
    "$ROOT/Resources/ModuleVoice" \
    "$STAGE_APP/Contents/Resources/ModuleVoice.payload" >/dev/null
fi
cp "$BIN_DIR/CellDock" "$STAGE_APP/Contents/MacOS/CellDock"
cp "$BIN_DIR/CellDockNetworkHelper" "$STAGE_APP/$HELPER_RELATIVE"
VOWIFI_GO_ROOT="$ROOT/ThirdParty/vowifi-go"
[[ -f "$VOWIFI_GO_ROOT/go.mod" && -d "$VOWIFI_GO_ROOT/vendor" ]] || {
  print -u2 "Vendored vowifi-go runtime source is missing."
  exit 1
}
mkdir -p "$STAGE_DIR/vowifi"
for GO_ARCH in arm64 amd64; do
  OUTPUT_ARCH="$GO_ARCH"
  [[ "$GO_ARCH" == amd64 ]] && OUTPUT_ARCH="x86_64"
  (
    cd "$VOWIFI_GO_ROOT"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$GO_ARCH" \
      go build -mod=vendor -trimpath -ldflags='-s -w' \
      -o "$STAGE_DIR/vowifi/CellDockVoWiFiRuntime-$OUTPUT_ARCH" \
      ./cmd/celldock-vowifi-runtime
  )
done
lipo -create \
  "$STAGE_DIR/vowifi/CellDockVoWiFiRuntime-arm64" \
  "$STAGE_DIR/vowifi/CellDockVoWiFiRuntime-x86_64" \
  -output "$STAGE_APP/$VOWIFI_RUNTIME_RELATIVE"
chmod 0755 "$STAGE_APP/$VOWIFI_RUNTIME_RELATIVE"
cp "$ROOT/Resources/app.celldock.mac.network.helper.plist" "$STAGE_APP/$PLIST_RELATIVE"
[[ -d "$SPARKLE_FRAMEWORK_SOURCE" ]] || {
  print -u2 "SwiftPM did not resolve the Sparkle framework."
  exit 1
}
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$STAGE_APP/$SPARKLE_FRAMEWORK_RELATIVE"

xattr -cr "$STAGE_APP"
SPARKLE_FRAMEWORK="$STAGE_APP/$SPARKLE_FRAMEWORK_RELATIVE"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  --identifier app.celldock.mac.vowifi.runtime \
  "$STAGE_APP/$VOWIFI_RUNTIME_RELATIVE"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  --preserve-metadata=entitlements \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  "$SPARKLE_VERSION/Autoupdate"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  "$SPARKLE_VERSION/Updater.app"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  "$SPARKLE_FRAMEWORK"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  "${HELPER_REQUIREMENT_OPTIONS[@]}" \
  --identifier app.celldock.mac.network.helper \
  "$STAGE_APP/$HELPER_RELATIVE"
codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  "${CODESIGN_OPTIONS[@]}" \
  "${APP_REQUIREMENT_OPTIONS[@]}" \
  --identifier app.celldock.mac \
  --entitlements "$ROOT/Resources/CellDock.entitlements" \
  "$STAGE_APP"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

for signed_code in \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION/Autoupdate" \
  "$SPARKLE_VERSION/Updater.app" \
  "$SPARKLE_FRAMEWORK" \
  "$STAGE_APP/$VOWIFI_RUNTIME_RELATIVE" \
  "$STAGE_APP/$HELPER_RELATIVE" \
  "$STAGE_APP"; do
  codesign \
    --verify \
    --strict \
    --verbose=2 \
    --test-requirement "=certificate leaf = H\"$SIGN_CERT_SHA1\"" \
    "$signed_code"
done
if [[ "$SIGNING_MODE" == development && -d /Applications/CellDock.app ]]; then
  EXISTING_TEAM_ID="$(codesign -dvv /Applications/CellDock.app 2>&1 | awk -F= '$1 == "TeamIdentifier" && !found { print $2; found=1 }')"
  SIGNED_TEAM_ID="$(codesign -dvv "$STAGE_APP" 2>&1 | awk -F= '$1 == "TeamIdentifier" && !found { print $2; found=1 }')"
  [[ -n "$EXISTING_TEAM_ID" && "$SIGNED_TEAM_ID" == "$EXISTING_TEAM_ID" ]] || {
    print -u2 "Development signing Team ID does not match the installed CellDock app."
    print -u2 "Refusing to replace an app that may own incompatible Keychain records."
    exit 1
  }
fi

ditto -c -k --sequesterRsrc "$STAGE_PACKAGE_DIR" "$STAGE_ZIP"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$STAGE_ZIP" "$VERIFY_DIR"

VERIFY_BINARY="$VERIFY_APP/Contents/MacOS/CellDock"
VERIFY_HELPER="$VERIFY_APP/$HELPER_RELATIVE"
VERIFY_VOWIFI_RUNTIME="$VERIFY_APP/$VOWIFI_RUNTIME_RELATIVE"
VERIFY_PLIST="$VERIFY_APP/$PLIST_RELATIVE"
VERIFY_SPARKLE="$VERIFY_APP/$SPARKLE_FRAMEWORK_RELATIVE"
codesign --verify --deep --strict --verbose=2 "$VERIFY_APP"
codesign --verify --strict --verbose=2 "$VERIFY_HELPER"
codesign --verify --strict --verbose=2 "$VERIFY_VOWIFI_RUNTIME"
codesign --verify --deep --strict --verbose=2 "$VERIFY_SPARKLE"
if [[ "$SIGNING_MODE" != development ]]; then
  for hardened_code in "$VERIFY_APP" "$VERIFY_HELPER" "$VERIFY_VOWIFI_RUNTIME"; do
    HARDENED_SIGNING_INFO="$(codesign -dvv "$hardened_code" 2>&1)"
    [[ "$HARDENED_SIGNING_INFO" == *flags=*runtime* ]] || {
      print -u2 "Archive code is missing hardened runtime: $hardened_code"
      exit 1
    }
  done
fi
# Check both slices of the extracted archive: a valid signature alone does not
# guarantee that hardened-runtime builds can request privacy permissions.
for architecture in arm64 x86_64; do
  VERIFY_ENTITLEMENTS="$VERIFY_DIR/CellDock-$architecture.entitlements"
  codesign --display --arch "$architecture" --entitlements - --xml \
    "$VERIFY_APP" > "$VERIFY_ENTITLEMENTS"
  for entitlement in \
    com.apple.security.device.audio-input \
    com.apple.security.personal-information.addressbook; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$VERIFY_ENTITLEMENTS")" == true ]] || {
      print -u2 "Archive is missing required entitlement $entitlement for $architecture."
      exit 1
    }
  done
done
plutil -lint "$VERIFY_APP/Contents/Info.plist"
plutil -lint "$VERIFY_PLIST"
[[ "$(plutil -extract CFBundleShortVersionString raw "$VERIFY_APP/Contents/Info.plist")" == "$VERSION" ]] || {
  print -u2 "Archive Info.plist version does not match $VERSION."
  exit 1
}
[[ "$(plutil -extract CFBundleVersion raw "$VERIFY_APP/Contents/Info.plist")" == "$BUILD_VERSION" ]] || {
  print -u2 "Archive Info.plist build version does not match $BUILD_VERSION."
  exit 1
}
[[ "$(plutil -extract CFBundleIdentifier raw "$VERIFY_APP/Contents/Info.plist")" == "app.celldock.mac" ]] || {
  print -u2 "Archive app bundle identifier is incorrect."
  exit 1
}
[[ "$(plutil -extract CFBundleExecutable raw "$VERIFY_APP/Contents/Info.plist")" == "CellDock" ]] || {
  print -u2 "Archive app executable name is incorrect."
  exit 1
}
[[ "$(plutil -extract CFBundleDisplayName raw "$VERIFY_APP/Contents/Info.plist")" == "CellDock" ]] || {
  print -u2 "Archive app display name is incorrect."
  exit 1
}
if find "$VERIFY_DIR" -type f \
  \( -name 'THIRD_PARTY_NOTICES.md' \
     -o -name 'COPYING-LGPL-2.1' \
     -o -name 'COPYING-GPL-2.0' \
     -o -name 'COPYING-cJSON-MIT' \) \
  -print -quit | grep -q .; then
  print -u2 "Archive includes a license or notices file excluded from distribution."
  exit 1
fi
if find "$VERIFY_APP/Contents/Resources" -type f \
  \( -name 'THIRD_PARTY_NOTICES.md' -o -name 'MODULE-REPORT.md' \) \
  -print -quit | grep -q .; then
  print -u2 "Archive includes a documentation file excluded from app resources."
  exit 1
fi
[[ ! -e "$VERIFY_APP/Contents/Resources/ModuleVoice-Notices" ]] || {
  print -u2 "Archive includes the unused ModuleVoice-Notices app resource."
  exit 1
}
cmp -s \
  "$ROOT/Resources/sim.svg" \
  "$VERIFY_APP/Contents/Resources/sim.svg" || {
  print -u2 "Archive SIM account icon does not match the source resource."
  exit 1
}
cmp -s \
  "$ROOT/Resources/sim1.svg" \
  "$VERIFY_APP/Contents/Resources/sim1.svg" || {
  print -u2 "Archive Pro account icon does not match the source resource."
  exit 1
}
cmp -s \
  "$ROOT/Resources/celldock-module-vertical.svg" \
  "$VERIFY_APP/Contents/Resources/celldock-module-vertical.svg" || {
  print -u2 "Packaged device module SVG does not match the source resource."
  exit 1
}
for sound_file in "$ROOT/Resources/Sounds/"*; do
  cmp \
    "$sound_file" \
    "$VERIFY_APP/Contents/Resources/Sounds/${sound_file:t}"
done
for language in zh-Hans en ja fr; do
  localization_dir="$VERIFY_APP/Contents/Resources/$language.lproj"
  [[ -d "$localization_dir" ]] || {
    print -u2 "Archive is missing the $language localization."
    exit 1
  }
  plutil -lint "$localization_dir/Localizable.strings"
  plutil -lint "$localization_dir/InfoPlist.strings"
done
if [[ -d "$ROOT/Resources/ModuleVoice" ]]; then
  [[ -f "$VERIFY_APP/Contents/Resources/ModuleVoice.payload" ]] || {
    print -u2 "Archive is missing the QDC507 voice runtime."
    exit 1
  }
  cmp \
    "$STAGE_APP/Contents/Resources/ModuleVoice.payload" \
    "$VERIFY_APP/Contents/Resources/ModuleVoice.payload"
  if find "$VERIFY_APP" -type f -name '*.ko' -print -quit | grep -q .; then
    print -u2 "Archive exposes a standalone kernel module."
    exit 1
  fi
fi

VERIFY_BINARY_ARCHS=" $(lipo -archs "$VERIFY_BINARY") "
[[ "$VERIFY_BINARY_ARCHS" == *" arm64 "* && "$VERIFY_BINARY_ARCHS" == *" x86_64 "* ]] || {
  print -u2 "Archive executable is not Universal 2 (arm64 + x86_64)."
  exit 1
}
VERIFY_HELPER_ARCHS=" $(lipo -archs "$VERIFY_HELPER") "
[[ "$VERIFY_HELPER_ARCHS" == *" arm64 "* && "$VERIFY_HELPER_ARCHS" == *" x86_64 "* ]] || {
  print -u2 "Archive helper is not Universal 2 (arm64 + x86_64)."
  exit 1
}
VERIFY_VOWIFI_ARCHS=" $(lipo -archs "$VERIFY_VOWIFI_RUNTIME") "
[[ "$VERIFY_VOWIFI_ARCHS" == *" arm64 "* && "$VERIFY_VOWIFI_ARCHS" == *" x86_64 "* ]] || {
  print -u2 "Archive VoWiFi runtime is not Universal 2 (arm64 + x86_64)."
  exit 1
}
[[ "$(plutil -extract LSMinimumSystemVersion raw "$VERIFY_APP/Contents/Info.plist")" == "14.0" ]] || {
  print -u2 "Archive Info.plist does not require macOS 14.0."
  exit 1
}
[[ "$(vtool -show-build "$VERIFY_BINARY" | awk '$1 == "minos" { print $2; exit }')" == "14.0" ]] || {
  print -u2 "Archive executable minOS is not 14.0."
  exit 1
}
[[ "$(vtool -show-build "$VERIFY_HELPER" | awk '$1 == "minos" { print $2; exit }')" == "14.0" ]] || {
  print -u2 "Archive helper minOS is not 14.0."
  exit 1
}
# Every architecture of the Swift-linked executables must record the
# deployment target and the installed SDK; otherwise macOS runs the app in
# compatibility mode with the old window appearance.
for linked_binary in "$VERIFY_BINARY" "$VERIFY_HELPER"; do
  for architecture in arm64 x86_64; do
    BUILD_INFO="$(vtool -arch "$architecture" -show-build "$linked_binary")"
    RECORDED_MINOS="$(print -r -- "$BUILD_INFO" | awk '$1 == "minos" { print $2; exit }')"
    RECORDED_SDK="$(print -r -- "$BUILD_INFO" | awk '$1 == "sdk" { print $2; exit }')"
    [[ "$RECORDED_MINOS" == "$DEPLOYMENT_TARGET" && "$RECORDED_SDK" == "$MACOS_SDK_VERSION" ]] || {
      print -u2 "${linked_binary:t} ($architecture) records minos $RECORDED_MINOS / sdk $RECORDED_SDK; expected $DEPLOYMENT_TARGET / $MACOS_SDK_VERSION."
      exit 1
    }
  done
done
# The VoWiFi runtime is linked by Go's internal linker (CGO disabled), which
# writes its own fixed minimum and SDK versions. It is a helper process with
# no UI, so only require that it runs on the app's minimum macOS.
autoload -Uz is-at-least
for architecture in arm64 x86_64; do
  VOWIFI_MINOS="$(vtool -arch "$architecture" -show-build "$VERIFY_VOWIFI_RUNTIME" | awk '$1 == "minos" { print $2; exit }')"
  [[ -n "$VOWIFI_MINOS" ]] && is-at-least "$VOWIFI_MINOS" "$DEPLOYMENT_TARGET" || {
    print -u2 "VoWiFi runtime ($architecture) requires macOS ${VOWIFI_MINOS:-unknown}, above $DEPLOYMENT_TARGET."
    exit 1
  }
done
[[ "$(codesign -dvv "$VERIFY_BINARY" 2>&1 | awk -F= '$1 == "Identifier" { print $2; exit }')" == "app.celldock.mac" ]] || {
  print -u2 "Archive executable signing identifier is incorrect."
  exit 1
}
[[ "$(codesign -dvv "$VERIFY_HELPER" 2>&1 | awk -F= '$1 == "Identifier" { print $2; exit }')" == "app.celldock.mac.network.helper" ]] || {
  print -u2 "Archive helper signing identifier is incorrect."
  exit 1
}
[[ "$(plutil -extract Label raw "$VERIFY_PLIST")" == "app.celldock.mac.network.helper" ]] || {
  print -u2 "LaunchDaemon label is incorrect."
  exit 1
}
[[ "$(plutil -extract ProgramArguments.0 raw "$VERIFY_PLIST")" == "/Library/PrivilegedHelperTools/CellDockNetworkHelper" ]] || {
  print -u2 "LaunchDaemon helper path is incorrect."
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:app.celldock.mac.network.helper' "$VERIFY_PLIST")" == "true" ]] || {
  print -u2 "LaunchDaemon Mach service is missing."
  exit 1
}

while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*|@rpath/Sparkle.framework/*) ;;
    *)
      print -u2 "Archive contains a non-system dynamic dependency: $dependency"
      exit 1
      ;;
  esac
done < <(otool -L "$VERIFY_BINARY" | awk '/^[[:space:]]/ { print $1 }')

while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *)
      print -u2 "Archive helper contains a non-system dynamic dependency: $dependency"
      exit 1
      ;;
  esac
done < <(otool -L "$VERIFY_HELPER" | awk '/^[[:space:]]/ { print $1 }')

cp "$STAGE_ZIP" "$PUBLISH_ZIP"
cmp "$STAGE_ZIP" "$PUBLISH_ZIP"
mv -f "$PUBLISH_ZIP" "$ZIP"

if [[ "$AUTO_INCREMENT_BUILD_VERSION" == true ]]; then
  plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$ROOT/Resources/Info.plist"
  print "Advanced CellDock build version: $SOURCE_BUILD_VERSION -> $BUILD_VERSION"
fi

# A loose app inside this FileProvider workspace receives FinderInfo after
# signing, invalidating strict verification. Keep the verified ZIP canonical.
rm -rf -- "$APP"
find "$OUTPUT_DIR" -maxdepth 1 -type d -name 'CellDock.previous.*.app' \
  -exec rm -rf -- {} +
find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'CellDock-*-universal.zip.previous.*' \
  -exec rm -f -- {} +
print "Verified archive: $ZIP"
