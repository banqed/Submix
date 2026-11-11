#!/bin/zsh
# Builds Submix.app next to this script.
set -e
cd "$(dirname "$0")"
APP=Submix.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Fonts/ChicagoFLF.ttf $APP/Contents/Resources/
swiftc -O -swift-version 5 -parse-as-library Sources/*.swift -o $APP/Contents/MacOS/Submix
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Submix</string>
  <key>CFBundleIdentifier</key><string>com.banqed.submix</string>
  <key>CFBundleExecutable</key><string>Submix</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Submix reads the sound of the apps you add so it can mix them and play them to your chosen output.</string>
</dict></plist>
PLIST
# Sign with a stable local identity if one exists, so privacy grants
# (System Audio Recording) survive rebuilds. Ad-hoc signing ties them
# to the binary hash instead, so they silently stop working after each build.
IDENTITY="${SIGN_IDENTITY:-Tyler Local Code Signing}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" $APP
else
  echo "warning: '$IDENTITY' not found, ad-hoc signing (permissions reset each build)"
  codesign --force --sign - $APP
fi
echo "Built $PWD/$APP"
