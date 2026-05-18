// clipboard-rtf.swift
// Holt den RTF-Flavor aus dem macOS-Clipboard und schreibt ihn nach stdout.
// Exit 1, wenn kein RTF vorhanden ist.
//
// Warum gibt es diesen Helper, wo es doch `pbpaste -Prefer rtf` gibt?
// Stellt sich heraus: `pbpaste -Prefer rtf` weicht auf Plain Text aus,
// sobald zusätzlich zum RTF auch RTFD (RTF mit eingebetteten Bildern)
// auf dem Clipboard liegt — was TextEdit & Co. standardmäßig tun, sobald
// das Dokument irgendetwas Eingebettetes hat. Das pbpaste-Verhalten ist
// undokumentiert und unzuverlässig.
//
// NSPasteboard.string(forType: .rtf) ist die direkte API, die uns
// genau den RTF-Flavor liefert, falls vorhanden — egal welche anderen
// Flavors danebenliegen.
//
// Kompilieren:
//   swiftc helpers/clipboard-rtf.swift -o helpers/clipboard-rtf

import AppKit  // bringt NSPasteboard mit

let pb = NSPasteboard.general

// .rtf ist die typsichere Konstante für die RTF-UTI ("public.rtf").
// Liefert nil, wenn kein RTF-Flavor auf dem Clipboard liegt.
if let rtf = pb.string(forType: .rtf) {
    print(rtf)
    exit(0)
} else {
    FileHandle.standardError.write("Kein RTF auf dem Clipboard.\n".data(using: .utf8)!)
    exit(1)
}
