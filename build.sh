#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Proxy Pulse"
EXEC="ProxyPulse"
SRC="ProxyPulse.swift"

echo ""
echo "🔨 Building ${APP_NAME}..."
echo ""

# ── Detect architecture ─────────────────────────────────────────────────────
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    TARGET="arm64-apple-macos26"
elif [[ "$ARCH" == "x86_64" ]]; then
    TARGET="x86_64-apple-macos26"
else
    TARGET="arm64-apple-macos26"
fi

# ── Compile ─────────────────────────────────────────────────────────────────
echo "  Compiling for ${ARCH}..."
swiftc -O \
    -o "$EXEC" \
    "$SRC" \
    -target "$TARGET" \
    -framework SwiftUI \
    -framework AppKit \
    2>&1

echo "  ✅ Compilation successful"

# ── Create .app bundle ──────────────────────────────────────────────────────
APP_DIR="${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mv "$EXEC" "$APP_DIR/Contents/MacOS/"
cp Info.plist "$APP_DIR/Contents/"

# ── Generate app icon (compass emoji rendered via sips) ─────────────────────
# We create a simple icon using a Python one-liner + CoreGraphics
python3 - "$APP_DIR/Contents/Resources" 2>/dev/null <<'PYEOF' || true
import subprocess, sys, os
res_dir = sys.argv[1]
# Create a 512x512 PNG with the compass emoji using sips-compatible approach
# Fallback: skip icon if tools unavailable
sizes = [16, 32, 64, 128, 256, 512]
iconset = os.path.join(res_dir, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for s in sizes:
    fname = f"icon_{s}x{s}.png"
    fpath = os.path.join(iconset, fname)
    # Create a minimal 1x1 orange PNG as placeholder
    import struct, zlib
    def make_png(w, h, r, g, b):
        def chunk(ctype, data):
            c = ctype + data
            return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
        raw = b''
        for _ in range(h):
            raw += b'\x00' + bytes([r, g, b]) * w
        return (b'\x89PNG\r\n\x1a\n' +
                chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                chunk(b'IDAT', zlib.compress(raw)) +
                chunk(b'IEND', b''))
    with open(fpath, 'wb') as f:
        f.write(make_png(s, s, 230, 97, 56))
    fname2 = f"icon_{s//2}x{s//2}@2x.png"
    if s >= 32:
        fpath2 = os.path.join(iconset, fname2)
        with open(fpath2, 'wb') as f:
            f.write(make_png(s, s, 230, 97, 56))
# Convert iconset to icns
subprocess.run(["iconutil", "-c", "icns", iconset, "-o",
                os.path.join(res_dir, "AppIcon.icns")], check=True)
import shutil
shutil.rmtree(iconset, ignore_errors=True)
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ ${APP_NAME}.app 构建完成!"
echo ""
echo "  运行:   open '${APP_NAME}.app'"
echo "  安装:   cp -r '${APP_NAME}.app' /Applications/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
