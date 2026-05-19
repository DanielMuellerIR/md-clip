// generate-dmg-background.swift
//
// Erzeugt das Hintergrundbild für das md-clip-DMG-Installationsfenster.
// Ausführen mit:
//
//   swift assets/generate-dmg-background.swift assets/dmg-background.png
//
// Ergebnis: 600×400-PNG, das im DMG hinter den beiden Icons liegt
// (md-clip.app links, Applications-Symlink rechts), mit Pfeil und
// Anleitungstext.
//
// Die Bildgröße ist exakt das, was die Finder-Fenstergröße im DMG
// einnimmt — sonst gibt es Skalierungs-Artefakte und das Layout
// stimmt nicht mit den Icon-Positionen überein.

import AppKit
import CoreGraphics

// ---------- Argumente ----------

let args = CommandLine.arguments
guard args.count == 2 else {
  FileHandle.standardError.write("Usage: swift generate-dmg-background.swift <output.png>\n".data(using: .utf8)!)
  exit(1)
}
let outputPath = args[1]

// ---------- Maße ----------

// Diese Maße müssen mit der Finder-Fenstergröße im AppleScript-Block
// in wrappers/sign-and-release.sh übereinstimmen.
let width: CGFloat  = 600
let height: CGFloat = 400

// Icon-Mittelpunkte. Müssen mit `set position of item "..."` im
// AppleScript zusammenpassen, sonst liegt der Pfeil nicht zwischen
// den Icons.
let appCenter:  CGPoint = CGPoint(x: 150, y: 180)  // y von oben gemessen
let dirCenter:  CGPoint = CGPoint(x: 450, y: 180)
let iconSize:   CGFloat = 128                       // wie Finder die Icons rendert

// ---------- Bitmap-Context vorbereiten ----------

// 2× Skalierung für Retina-Schärfe. macOS skaliert das PNG später
// passend; wir liefern intrinsisch 1200×800 mit DPI 144.
let scale: CGFloat = 2
let pxWidth  = Int(width  * scale)
let pxHeight = Int(height * scale)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
  data: nil,
  width: pxWidth,
  height: pxHeight,
  bitsPerComponent: 8,
  bytesPerRow: 0,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  FileHandle.standardError.write("CGContext-Erzeugung fehlgeschlagen\n".data(using: .utf8)!)
  exit(1)
}

// CoreGraphics hat den Ursprung unten-links. Damit unsere y-Koordinaten
// von oben gemessen sind (wie in HTML/Finder), kippen wir das Koordinaten-
// system einmal — der Rest des Codes denkt dann „top-down".
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: height)
ctx.scaleBy(x: 1, y: -1)

// ---------- Hintergrund: subtiler vertikaler Verlauf ----------

// Hell-grau oben, ein Tick dunkler unten. Wirkt ruhiger als pures Weiß,
// und die Icons heben sich besser ab.
let topColor    = CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1.0)
let bottomColor = CGColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1.0)

if let gradient = CGGradient(
  colorsSpace: colorSpace,
  colors: [topColor, bottomColor] as CFArray,
  locations: [0.0, 1.0]
) {
  ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end:   CGPoint(x: 0, y: height),
    options: []
  )
}

// ---------- Hilfsfunktion: Text zentriert zeichnen ----------

// NSAttributedString.draw erwartet AppKit-Koordinaten (Ursprung unten-links).
// Da wir den Kontext schon gekippt haben, müssen wir hier wieder lokal
// kippen, sonst steht der Text auf dem Kopf.
func drawCenteredText(
  _ text: String,
  at center: CGPoint,
  font: NSFont,
  color: NSColor
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center

  let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
    .paragraphStyle: paragraph,
  ]
  let attr = NSAttributedString(string: text, attributes: attrs)
  let size = attr.size()

  // Zielrechteck zentriert um (center.x, center.y), in unserem
  // top-down-Koordinatensystem.
  let rect = CGRect(
    x: center.x - size.width  / 2,
    y: center.y - size.height / 2,
    width:  size.width,
    height: size.height
  )

  // Lokal noch mal kippen, damit der Text richtig herum kommt.
  ctx.saveGState()
  ctx.translateBy(x: 0, y: rect.midY * 2)
  ctx.scaleBy(x: 1, y: -1)

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  attr.draw(in: rect)
  NSGraphicsContext.restoreGraphicsState()

  ctx.restoreGState()
}

// ---------- Texte ----------

let titleColor    = NSColor(white: 0.20, alpha: 1.0)
let subtitleColor = NSColor(white: 0.35, alpha: 1.0)

drawCenteredText(
  "md-clip installieren",
  at: CGPoint(x: width / 2, y: 50),
  font: NSFont.systemFont(ofSize: 22, weight: .semibold),
  color: titleColor
)

drawCenteredText(
  "Ziehe das md-clip-Symbol in den Ordner Programme.",
  at: CGPoint(x: width / 2, y: 82),
  font: NSFont.systemFont(ofSize: 13, weight: .regular),
  color: subtitleColor
)

drawCenteredText(
  "Danach öffne md-clip mit einem Doppelklick.",
  at: CGPoint(x: width / 2, y: 350),
  font: NSFont.systemFont(ofSize: 12, weight: .regular),
  color: subtitleColor
)

// ---------- Pfeil zwischen den Icon-Plätzen ----------

// Pfeil-Linie von rechts vom App-Icon zu links vom Applications-Icon.
// Padding sorgt dafür, dass er die Icons nicht überlappt.
let arrowPadding: CGFloat = iconSize / 2 + 20
let arrowStart = CGPoint(x: appCenter.x + arrowPadding, y: appCenter.y)
let arrowEnd   = CGPoint(x: dirCenter.x - arrowPadding, y: dirCenter.y)

let arrowColor = NSColor(white: 0.45, alpha: 1.0).cgColor
ctx.setStrokeColor(arrowColor)
ctx.setFillColor(arrowColor)
ctx.setLineWidth(3)
ctx.setLineCap(.round)

// Schaft.
ctx.move(to: arrowStart)
ctx.addLine(to: CGPoint(x: arrowEnd.x - 8, y: arrowEnd.y))
ctx.strokePath()

// Pfeilspitze als gefülltes Dreieck. Größe so gewählt, dass sie zur
// Linienstärke passt und nicht klobig wirkt.
let headLength: CGFloat = 18
let headWidth:  CGFloat = 14
ctx.beginPath()
ctx.move(to: arrowEnd)
ctx.addLine(to: CGPoint(x: arrowEnd.x - headLength, y: arrowEnd.y - headWidth / 2))
ctx.addLine(to: CGPoint(x: arrowEnd.x - headLength, y: arrowEnd.y + headWidth / 2))
ctx.closePath()
ctx.fillPath()

// ---------- PNG schreiben ----------

guard let cgImage = ctx.makeImage() else {
  FileHandle.standardError.write("Bild-Render fehlgeschlagen\n".data(using: .utf8)!)
  exit(1)
}

let rep = NSBitmapImageRep(cgImage: cgImage)
// DPI auf 144 setzen (= 2× von 72), damit der Finder das Bild als
// Retina-Asset behandelt und nicht hochskaliert.
rep.size = NSSize(width: width, height: height)

guard let pngData = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write("PNG-Encoding fehlgeschlagen\n".data(using: .utf8)!)
  exit(1)
}

let url = URL(fileURLWithPath: outputPath)
do {
  try pngData.write(to: url)
  print("✓ Geschrieben: \(outputPath) (\(pxWidth)×\(pxHeight) px)")
} catch {
  FileHandle.standardError.write("Schreiben fehlgeschlagen: \(error)\n".data(using: .utf8)!)
  exit(1)
}
