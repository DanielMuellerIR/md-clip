import AppKit
import Foundation

// pbpaste -Prefer rtf kann bei zusätzlich vorhandenem RTFD Klartext liefern.
if let rtf = NSPasteboard.general.string(forType: .rtf),
   rtf.range(of: #"\S"#, options: .regularExpression) != nil {
    FileHandle.standardOutput.write(Data(rtf.utf8))
    exit(0)
} else {
    FileHandle.standardError.write(Data("Kein RTF auf dem Clipboard.\n".utf8))
    exit(1)
}
