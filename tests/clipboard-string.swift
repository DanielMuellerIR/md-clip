// tests/clipboard-string.swift
// Liest den Plain-Text-Inhalt des Clipboards genau so, wie eine echte
// macOS-App ihn beim Einfügen sieht — via NSPasteboard.string(forType: .string).
// Schreibt die Zeichen als UTF-8 nach stdout (Swift's print() ist immer UTF-8),
// und zwar BYTEGENAU: kein angehängter Zeilenumbruch. Sonst könnte der Test
// nicht unterscheiden, ob ein Schluss-Newline vom Clipboard kommt oder vom
// Helfer selbst — genau das hat ein überzähliges LF im Clipboard verdeckt.
//
// Zweck: dieser Helper ist der „Goldstandard" für Tests, ob ein durch
// md-clip --replace geschriebener Clipboard-Inhalt korrekt encoded ist.
// Im Gegensatz zu `pbpaste`, das je nach LC_ALL die Bytes verschieden
// re-encoded, holt sich diese Swift-API die Zeichen direkt aus dem
// NSString-Eintrag des Clipboards. Wenn dieser Helper Mojibake sieht,
// sieht JEDE App, in die der Nutzer einfügt, dasselbe Mojibake.
//
// Kompilieren — in ein privates Temp-Verzeichnis, NICHT nach tests/:
//   HELPERS=$(mktemp -d)
//   swiftc tests/clipboard-string.swift -o "$HELPERS/clipboard-string"
// Der automatische Lauf (tests/run-tests.sh) macht es genauso; ein Bauen
// nach tests/ hinterliesse ein ungetracktes Binary im Arbeitsbaum.
//
// Exit 0: Plain-Text-Flavor vorhanden, wurde ausgegeben.
// Exit 1: kein Plain-Text-Flavor auf dem Clipboard.

import AppKit

let pb = NSPasteboard.general

// .string ist die generische Plain-Text-UTI (public.utf8-plain-text).
// Beim Lesen liefert NSPasteboard automatisch die korrekt dekodierte
// Swift-String-Repräsentation — wir sehen also tatsächlich die Zeichen
// und nicht irgendwelche Bytes in der falschen Codierung.
if let text = pb.string(forType: .string) {
    print(text, terminator: "")
    exit(0)
} else {
    FileHandle.standardError.write("Kein Plain-Text auf dem Clipboard.\n".data(using: .utf8)!)
    exit(1)
}
