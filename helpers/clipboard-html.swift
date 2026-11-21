import AppKit
import Foundation

func decodeHTML(_ data: Data) -> String? {
    // Ein BOM legt die Kodierung verbindlich fest. Fehlerhafte Daten sollen
    // den Klartext-Fallback auslösen und nicht als Latin-1 erscheinen.
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
guard let data = NSPasteboard.general.data(forType: .html) else {
    FileHandle.standardError.write(Data("Kein HTML auf dem Clipboard.\n".utf8))
    exit(1)
}
guard let html = decodeHTML(data) else {
    let message = "HTML auf dem Clipboard ist nicht dekodierbar (BOM passt nicht zum Inhalt).\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
guard html.range(of: #"\S"#, options: .regularExpression) != nil else {
    FileHandle.standardError.write(Data("HTML auf dem Clipboard ist leer.\n".utf8))
    exit(1)
}

FileHandle.standardOutput.write(Data(html.utf8))
exit(0)
