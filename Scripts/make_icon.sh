#!/usr/bin/env bash
#
# Generates the app icon from mark 1A: a three-stroke "C" monogram, white on
# solid #6C63E0. Also renders a template icon for the menu bar.
#
# Output:
#   Resources/AppIcon.icns
#   Resources/MenuBarIcon.png / MenuBarIcon@2x.png / MenuBarIcon@3x.png
#
# Usage: bash Scripts/make_icon.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
PNG="$WORK/icon_1024.png"
SWIFT="$WORK/draw.swift"
mkdir -p Resources

cat > "$SWIFT" <<'SWIFT'
import AppKit

// Mark 1A geometry, as fractions of the squircle side:
//   glyph  — 0.479 square, centred
//   stroke — 0.0833, square ends
// Three strokes (top, left, bottom) form a bracket open to the right.
let GLYPH_RATIO: CGFloat  = 0.479
let STROKE_RATIO: CGFloat = 0.0833
let SQUIRCLE_RADIUS: CGFloat = 0.2237   // fraction of the squircle width
let BRAND = NSColor(srgbRed: 0x6C / 255.0, green: 0x63 / 255.0, blue: 0xE0 / 255.0, alpha: 1)

/// Draws the monogram's three strokes inside rect in the given color.
func drawGlyph(in rect: CGRect, color: NSColor, ctx: CGContext) {
    let g = rect.width * GLYPH_RATIO
    let s = rect.width * STROKE_RATIO
    let x = rect.midX - g / 2
    let y = rect.midY - g / 2

    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(x: x, y: y + g - s, width: g, height: s))  // top
    ctx.fill(CGRect(x: x, y: y,         width: s, height: g))  // left
    ctx.fill(CGRect(x: x, y: y,         width: g, height: s))  // bottom
}

func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Не удалось отрендерить \(path)\n", stderr); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

// MARK: - App icon (1024 squircle, transparent margins)

let size: CGFloat = 1024
let app = NSImage(size: NSSize(width: size, height: size))
app.lockFocus()
if let ctx = NSGraphicsContext.current?.cgContext {
    let inset: CGFloat = 90
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * SQUIRCLE_RADIUS

    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(BRAND.cgColor)
    ctx.fillPath()

    drawGlyph(in: rect, color: .white, ctx: ctx)
}
app.unlockFocus()
writePNG(app, to: CommandLine.arguments[1])

// MARK: - Menu bar icon (black mark on transparent background, template)

for (side, suffix) in [(CGFloat(18), ""), (CGFloat(36), "@2x"), (CGFloat(54), "@3x")] {
    let bar = NSImage(size: NSSize(width: side, height: side))
    bar.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        // The menu bar mark fills more of its frame, or it gets lost.
        let box = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.06,
                                                                       dy: side * 0.06)
        drawGlyph(in: box, color: .black, ctx: ctx)
    }
    bar.unlockFocus()
    writePNG(bar, to: "\(CommandLine.arguments[2])/MenuBarIcon\(suffix).png")
}
SWIFT

echo "▶︎ Рендер знака 1024 px и иконок строки меню…"
swift "$SWIFT" "$PNG" "$ROOT/Resources"

echo "▶︎ Сборка iconset…"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
sips -z 16   16   "$PNG" --out "$SET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$PNG" --out "$SET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$PNG" --out "$SET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$PNG" --out "$SET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$PNG" --out "$SET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$PNG" --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$PNG" --out "$SET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$PNG" --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$PNG" --out "$SET/icon_512x512.png"    >/dev/null
cp "$PNG" "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$WORK"

echo "✅ Resources/AppIcon.icns"
echo "✅ Resources/MenuBarIcon{,@2x,@3x}.png (template — not bundled: the"
echo "   status bar shows the readings alone, no mark)"
