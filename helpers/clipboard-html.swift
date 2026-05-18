// clipboard-html.swift
// Holt den HTML-Flavor aus dem macOS-Clipboard und schreibt ihn nach stdout.
// Exit 1, wenn kein HTML vorhanden ist.
//
// Kompilieren: swiftc clipboard-html.swift -o clipboard-html
// Aufruf:      ./clipboard-html

import AppKit  // für NSPasteboard

// Das System-Clipboard, "general pasteboard" in macOS-Sprech.
let pb = NSPasteboard.general

// Den HTML-Inhalt holen. NSPasteboard.PasteboardType.html ist die
// standardisierte HTML-UTI ("public.html"). Liefert nil, wenn nichts da.
if let html = pb.string(forType: .html) {
    print(html)
    exit(0)
} else {
    // Kein HTML-Flavor auf dem Clipboard.
    FileHandle.standardError.write("Kein HTML auf dem Clipboard.\n".data(using: .utf8)!)
    exit(1)
}