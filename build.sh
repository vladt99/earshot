#!/bin/zsh
# Builds Earshot.app into dist/.
#   ./build.sh            build release + bundle
#   ./build.sh --open     build and launch from dist (stops the running one)
#   ./build.sh --install  build, copy to /Applications and launch from there
#   ./build.sh --zip      build and pack dist/Earshot.zip for a GitHub release
#
# Signing: ad-hoc by default. To keep macOS permissions (microphone, audio capture, accessibility)
# between builds, sign with a stable identity: put SIGN_IDENTITY (and optionally SIGN_KEYCHAIN,
# SIGN_KEYCHAIN_PASSWORD_FILE) in .signing.env, which is git-ignored.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP=dist/Earshot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Earshot" "$APP/Contents/MacOS/Earshot"
cp "$BIN/earshot-mcp" "$APP/Contents/MacOS/earshot-mcp"
cp Info.plist "$APP/Contents/Info.plist"
# Sparkle (auto-update). ditto keeps the framework's Versions/ symlinks. Earshot isn't sandboxed, so the installer
# and downloader XPC services go unused (Sparkle's docs allow removing them); headers aren't needed at run time.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
for d in XPCServices Headers PrivateHeaders Modules; do
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework/$d" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/$d"
done
# SwiftPM links with @loader_path only; the bundled app loads Sparkle from Contents/Frameworks. Signed below.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Earshot" 2>/dev/null
# App icon: Resources/AppIcon.png (1024×1024, full bleed: macOS applies its own mask) → AppIcon.icns, the fallback
if [[ -f Resources/AppIcon.png ]]; then
  SET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$SET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
# Asset catalog (CFBundleIconName): without it macOS 26 shows the icon shrunk on a grey rounded square. Needs Xcode.
if [[ -d Resources/Assets.xcassets ]]; then
  CAR=$(mktemp -d)
  if xcrun actool Resources/Assets.xcassets --compile "$CAR" --platform macosx --minimum-deployment-target 26.0 \
       --app-icon AppIcon --output-partial-info-plist "$CAR/partial.plist" >/dev/null; then
    cp "$CAR/Assets.car" "$APP/Contents/Resources/"
    [[ -f $CAR/AppIcon.icns ]] && cp "$CAR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  else
    echo "warning: actool failed (is Xcode installed?); using AppIcon.icns only" >&2
  fi
  rm -rf "$CAR"
fi
# SwiftPM resource bundles of dependencies
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

SIGN_IDENTITY=-
[[ -f .signing.env ]] && source .signing.env
if [[ -n ${SIGN_KEYCHAIN:-} ]]; then
  if [[ -n ${SIGN_KEYCHAIN_PASSWORD_FILE:-} ]]; then
    # Fed to `security -i` on stdin (print is a builtin), so the password never shows up in `ps`.
    PW="$(<"$SIGN_KEYCHAIN_PASSWORD_FILE")"
    PW=${PW//\\/\\\\}
    print -r -- "unlock-keychain -p \"${PW//\"/\\\"}\" \"${SIGN_KEYCHAIN//\"/\\\"}\"" | security -i
    unset PW
  fi
  codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP"
else
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
fi
echo "OK → $APP"

case "${1:-}" in
  --open)
    pkill -x Earshot 2>/dev/null || true
    sleep 0.5
    open "$APP"
    ;;
  --install)
    pkill -x Earshot 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Earshot.app
    cp -R "$APP" /Applications/Earshot.app
    open /Applications/Earshot.app
    echo "Installed in /Applications"
    ;;
  --zip)
    # The public build is always signed ad hoc, so no local certificate name ends up in the release,
    # and packed without extended attributes or resource forks.
    STAGE=$(mktemp -d)
    ditto --norsrc --noextattr "$APP" "$STAGE/Earshot.app"
    codesign --force --deep --sign - "$STAGE/Earshot.app"
    rm -f dist/Earshot.zip
    ditto -c -k --norsrc --noextattr --keepParent "$STAGE/Earshot.app" dist/Earshot.zip
    rm -rf "$STAGE"
    shasum -a 256 dist/Earshot.zip
    echo "OK → dist/Earshot.zip"
    ;;
esac
