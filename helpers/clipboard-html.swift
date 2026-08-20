// clipboard-html.swift
// Holt den HTML-Flavor aus dem macOS-Clipboard und schreibt ihn nach stdout.
// Exit 1, wenn kein HTML vorhanden ist.
//
// Kompilieren: swiftc clipboard-html.swift -o clipboard-html
// Aufruf:      ./clipboard-html

import AppKit  // für NSPasteboard
import Foundation

// Das System-Clipboard, "general pasteboard" in macOS-Sprech.
let pb = NSPasteboard.general

func decodeHTML(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(3))

    if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
        return String(data: data, encoding: .utf16)
    }
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
        return String(data: Data(data.dropFirst(3)), encoding: .utf8)
    }
    if let utf8 = String(data: data, encoding: .utf8) {
        return utf8
    }
    // Alte Clipboard-Quellen liefern gelegentlich Latin-1 ohne Kennzeichnung.
    return String(data: data, encoding: .isoLatin1)
}

// Daten statt string(forType:) lesen: NSPasteboard garantiert für public.html
// keine UTF-8-Kodierung. Damit bleiben auch UTF-16 mit BOM und Latin-1 lesbar.
guard let data = pb.data(forType: .html) else {
    FileHandle.standardError.write("Kein HTML auf dem Clipboard.\n".data(using: .utf8)!)
    exit(1)
}
guard let html = decodeHTML(data) else {
    FileHandle.standardError.write("HTML auf dem Clipboard ist nicht dekodierbar.\n".data(using: .utf8)!)
    exit(2)
}
guard html.range(of: #"\S"#, options: .regularExpression) != nil else {
    FileHandle.standardError.write("HTML auf dem Clipboard ist leer.\n".data(using: .utf8)!)
    exit(1)
}

FileHandle.standardOutput.write(Data(html.utf8))
exit(0)
