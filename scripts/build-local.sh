#!/bin/zsh
# Local Apple silicon build with Command Line Tools (Swift 6.2+, macOS 26 SDK).
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $(uname -m) == arm64 ]] || { echo "This build requires Apple silicon." >&2; exit 1; }
SDK=$(xcrun --show-sdk-path)
WORK="$PWD/build/local"
APP="$WORK/Compositor.app"
mkdir -p "$WORK"

# Keep the binary dependency pinned to the Xcode project's resolved version.
SPARKLE_VERSION=$(plutil -extract pins.0.state.version raw Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
[[ "$SPARKLE_VERSION" == 2.10.0 ]] || { echo "Update the Sparkle checksum in this script for $SPARKLE_VERSION." >&2; exit 1; }
ZIP="$WORK/Sparkle-$SPARKLE_VERSION.zip"
if [[ ! -f "$ZIP" ]]; then
    curl -fL --retry 2 "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip" -o "$ZIP"
fi
echo "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959  $ZIP" | shasum -a 256 -c -
ditto -x -k "$ZIP" "$WORK/Sparkle"
FRAMEWORKS="$WORK/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"

mkdir -p "$APP/Contents/"{MacOS,Resources,Frameworks} "$WORK/objects" "$WORK/strings"
for source in Compositor/Rendering/*.c; do
    xcrun clang -O3 -target arm64-apple-macosx15.0 -isysroot "$SDK" -c "$source" -o "$WORK/objects/${source:t:r}.o"
done
xcrun swiftc -O -whole-module-optimization -module-name Compositor -swift-version 5 \
    -emit-localized-strings -emit-localized-strings-path "$WORK/strings" \
    -target arm64-apple-macosx15.0 -sdk "$SDK" -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature MemberImportVisibility \
    -import-objc-header Compositor/Compositor-Bridging-Header.h \
    -F "$FRAMEWORKS" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Compositor/**/*.swift "$WORK"/objects/*.o -o "$APP/Contents/MacOS/Compositor"
ditto "$FRAMEWORKS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
ditto Compositor/zh-Hans.lproj "$APP/Contents/Resources/zh-Hans.lproj"

# Command Line Tools has no asset catalog compiler; package the existing icon with iconutil.
mkdir -p "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
    cp "Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-$size.png" "$WORK/AppIcon.iconset/icon_${size}x${size}.png"
    cp "Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-$((size * 2)).png" "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

python3 - "$APP" "$WORK" <<'PY'
import pathlib, plistlib, subprocess, sys

app, work = map(pathlib.Path, sys.argv[1:])
project = plistlib.loads(subprocess.check_output([
    'plutil', '-convert', 'xml1', '-o', '-', 'Compositor.xcodeproj/project.pbxproj']))
settings = next(obj['buildSettings'] for obj in project['objects'].values()
                if obj.get('name') == 'Release' and 'PRODUCT_BUNDLE_IDENTIFIER' in obj.get('buildSettings', {})
                and obj['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] == 'com.wonderassembly.compositor')
targets = [obj['buildSettings']['MACOSX_DEPLOYMENT_TARGET'] for obj in project['objects'].values()
           if 'MACOSX_DEPLOYMENT_TARGET' in obj.get('buildSettings', {})]
assert targets and set(targets) == {'15.0'}, targets
info = plistlib.loads(pathlib.Path('Config/Info.plist').read_bytes())
info.update(CFBundleExecutable='Compositor', CFBundleName='Compositor', CFBundlePackageType='APPL', CFBundleDevelopmentRegion='en',
            CFBundleIdentifier=settings['PRODUCT_BUNDLE_IDENTIFIER'],
            CFBundleShortVersionString=settings['MARKETING_VERSION'], CFBundleVersion=settings['CURRENT_PROJECT_VERSION'],
            CFBundleIconFile='AppIcon', LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True,
            LSApplicationCategoryType='public.app-category.graphics-design', SUEnableAutomaticChecks=False)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
entitlements = pathlib.Path('Config/Compositor.entitlements').read_text().replace(
    '$(PRODUCT_BUNDLE_IDENTIFIER)', settings['PRODUCT_BUNDLE_IDENTIFIER'])
(work / 'Compositor.entitlements').write_text(entitlements)
assert plistlib.loads(entitlements.encode())['com.apple.security.app-sandbox'] is True
PY

xcrun strip -S -x "$APP/Contents/MacOS/Compositor"
codesign --force --sign - --entitlements "$WORK/Compositor.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
echo "Built $APP"
