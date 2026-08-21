// tests/load-clipboard.swift
// Lädt eine Datei mit einem bestimmten Flavor auf das macOS-Clipboard.
// Nur für Tests gedacht — Produktiv-Code soll das Clipboard nie überschreiben.
//
// Aufruf:
//   load-clipboard <pasteboard-type> <datei>
//
// Beispiele:
//   "$HELPERS/load-clipboard" public.rtf  tests/fixtures/word-rtf.rtf
//   "$HELPERS/load-clipboard" public.html tests/fixtures/safari-article.html
//
// Kompilieren — in ein privates Temp-Verzeichnis, NICHT nach tests/:
//   HELPERS=$(mktemp -d)
//   swiftc tests/load-clipboard.swift -o "$HELPERS/load-clipboard"
// Der automatische Lauf (tests/run-tests.sh) macht es genauso. Ein Bauen
// nach tests/ hinterliesse ein ungetracktes Binary im Arbeitsbaum und
// widerspraeche der Zusage im README, dass ein sauberer Checkout ohne
// lokale Alt-Binaries auskommt.

import AppKit
import Foundation

// Erwartet (type, datei)-Paare als Argumente. Mindestens ein Paar.
//   load-clipboard public.html foo.html
//   load-clipboard public.html foo.html public.rtf foo.rtf
let args = Array(CommandLine.arguments.dropFirst())  // ohne Programmname
guard args.count >= 2, args.count % 2 == 0 else {
    FileHandle.standardError.write(
        "Usage: load-clipboard <type> <file> [<type> <file>...]\n".data(using: .utf8)!
    )
    exit(2)
}

let pb = NSPasteboard.general
// Pflicht-Erstaufruf vor jedem Schreibzugriff.
pb.clearContents()

// Paarweise durchgehen. Stride mit Schritt 2 liefert 0, 2, 4, ...
for i in stride(from: 0, to: args.count, by: 2) {
    let typeStr = args[i]
    let path = args[i + 1]

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write(
            "Datei nicht lesbar: \(path)\n".data(using: .utf8)!
        )
        exit(1)
    }

    let type = NSPasteboard.PasteboardType(typeStr)
    if pb.setData(data, forType: type) {
        print("OK: \(data.count) Bytes als \(typeStr) gesetzt.")
    } else {
        FileHandle.standardError.write(
            "setData fehlgeschlagen für Typ \(typeStr)\n".data(using: .utf8)!
        )
        exit(1)
    }
}

exit(0)
