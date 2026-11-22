#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OllamaTranslator"
BUNDLE_ID="com.local.OllamaTranslator"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

cd "$PROJECT_DIR"

echo "==> Building $APP_NAME (release)..."
ARCH="$(uname -m)"
BUILD_DIR="$PROJECT_DIR/.build/release"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE"
BIN_PATH="$BUILD_DIR/$APP_NAME"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

swiftc -O \
    -module-cache-path "$MODULE_CACHE" \
    -target "${ARCH}-apple-macosx13.0" \
    -framework Carbon \
    -framework AppKit \
    -framework SwiftUI \
    -framework ApplicationServices \
    -framework AVFoundation \
    "$PROJECT_DIR"/Sources/OllamaTranslator/*.swift \
    -o "$BIN_PATH"

echo "==> Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Bundle native Rust Kokoro TTS binary if built (or build offline if Cargo cache exists)
RUST_BIN="$PROJECT_DIR/rust-tts/target/release/kokoro-tts-rs"
if [ ! -f "$RUST_BIN" ] && [ -f "$PROJECT_DIR/rust-tts/Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
    echo "==> Building native Rust Kokoro TTS engine (kokoro-tts-rs)..."
    cargo build --release --manifest-path "$PROJECT_DIR/rust-tts/Cargo.toml" || true
fi
if [ -f "$RUST_BIN" ]; then
    echo "==> Bundling native Rust TTS binary (kokoro-tts-rs)..."
    cp "$RUST_BIN" "$APP_BUNDLE/Contents/MacOS/kokoro-tts-rs"
    chmod +x "$APP_BUNDLE/Contents/MacOS/kokoro-tts-rs"
fi

if [ -f "$PROJECT_DIR/scripts/kokoro_tts_server.py" ]; then
    cp "$PROJECT_DIR/scripts/kokoro_tts_server.py" "$APP_BUNDLE/Contents/Resources/kokoro_tts_server.py"
    chmod +x "$APP_BUNDLE/Contents/Resources/kokoro_tts_server.py"
fi

# Generate crisp native app icon (.icns) using Swift + sips + iconutil
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
BASE_ICON="$PROJECT_DIR/.build/icon_1024.png"
rm -rf "$ICONSET_DIR" "$BASE_ICON"
mkdir -p "$ICONSET_DIR"

swift -module-cache-path "$MODULE_CACHE" - "$BASE_ICON" <<'SWIFT'
import AppKit
import Foundation

let outPath = CommandLine.arguments[1]
let px = 1024
let size = NSSize(width: px, height: px)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: px,
    pixelsHigh: px,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(origin: .zero, size: size)
let inset = CGFloat(px) * 0.09
let cardRect = rect.insetBy(dx: inset, dy: inset)
let corner = CGFloat(px) * 0.22

let path = NSBezierPath(roundedRect: cardRect, xRadius: corner, yRadius: corner)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.96, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.88, alpha: 1.0)
)!
gradient.draw(in: path, angle: -45)

NSColor.white.withAlphaComponent(0.24).setStroke()
path.lineWidth = 14
path.stroke()

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 330, weight: .bold),
    .foregroundColor: NSColor.white
]
let str = NSAttributedString(string: "A⇄Я", attributes: attrs)
let textSize = str.size()
str.draw(at: NSPoint(
    x: (CGFloat(px) - textSize.width) / 2.0,
    y: (CGFloat(px) - textSize.height) / 2.0
))

NSGraphicsContext.restoreGraphicsState()

if let pngData = rep.representation(using: .png, properties: [:]) {
    try pngData.write(to: URL(fileURLWithPath: outPath))
}
SWIFT

if [ -f "$BASE_ICON" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    sips -z 16 16     "$BASE_ICON" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
    sips -z 32 32     "$BASE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
    sips -z 32 32     "$BASE_ICON" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
    sips -z 64 64     "$BASE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
    sips -z 128 128   "$BASE_ICON" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
    sips -z 256 256   "$BASE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$BASE_ICON" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
    sips -z 512 512   "$BASE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$BASE_ICON" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
    cp "$BASE_ICON"                      "$ICONSET_DIR/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || python3 - "$ICONSET_DIR" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" <<'PY'
import os, struct, sys

iconset, out_icns = sys.argv[1], sys.argv[2]
mapping = [
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
]
chunks = bytearray()
for ostype, fname in mapping:
    p = os.path.join(iconset, fname)
    if os.path.exists(p):
        data = open(p, "rb").read()
        chunks += ostype + struct.pack(">I", len(data) + 8) + data
with open(out_icns, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
PY
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.5.0</string>
    <key>CFBundleVersion</key>
    <string>7</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"

echo "==> Done! App bundle created at:"
echo "    $APP_BUNDLE"
