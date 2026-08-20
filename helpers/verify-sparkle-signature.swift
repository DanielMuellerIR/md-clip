// Prüft eine Sparkle-Ed25519-Signatur gegen den öffentlichen Schlüssel der
// ausgelieferten App. Der Appcast-Workflow kompiliert diesen kleinen Helfer aus
// einer fest gepinnten Tooling-Revision und übergibt ihm ausschließlich Daten.

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("Aufruf: verify-sparkle-signature <public-key-base64> <signature-base64> <datei>\n".utf8))
    exit(64)
}

let publicKeyText = CommandLine.arguments[1]
let signatureText = CommandLine.arguments[2]
let filePath = CommandLine.arguments[3]

guard let publicKeyData = Data(base64Encoded: publicKeyText),
      let signatureData = Data(base64Encoded: signatureText) else {
    FileHandle.standardError.write(Data("Öffentlicher Schlüssel oder Signatur ist kein gültiges Base64.\n".utf8))
    exit(65)
}

do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let artifact = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signatureData, for: artifact) else {
        FileHandle.standardError.write(Data("Sparkle-Signatur passt nicht zum Release-Artefakt und öffentlichen Schlüssel.\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("Sparkle-Signatur konnte nicht geprüft werden: \(error)\n".utf8))
    exit(65)
}
