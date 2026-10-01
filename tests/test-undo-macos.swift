import AppKit
import Foundation
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)
let helper = CommandLine.arguments[1]
let root = CommandLine.arguments[2]
let board = NSPasteboard.withUniqueName()
var environment = ProcessInfo.processInfo.environment
environment["MD_CLIP_TEST_PASTEBOARD"] = board.name.rawValue
environment["MD_CLIP_TEST_DIRECTORY"] = root + "/service"
let service = environment["MD_CLIP_TEST_DIRECTORY"]!
struct Result { let status: Int32; let output: String; let error: String }
func launch(_ arguments: [String], _ input: Data? = nil) -> (Process, Pipe, Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helper)
    process.arguments = arguments
    process.environment = environment
    let output = Pipe(), error = Pipe()
    process.standardOutput = output
    process.standardError = error
    if let input {
        let pipe = Pipe()
        process.standardInput = pipe
        try! process.run()
        try! pipe.fileHandleForWriting.write(contentsOf: input)
        try! pipe.fileHandleForWriting.close()
    } else {
        process.standardInput = FileHandle.nullDevice
        try! process.run()
    }
    return (process, output, error)
}
func finish(_ launched: (Process, Pipe, Pipe)) -> Result {
    let (process, output, error) = launched
    let deadline = Date().addingTimeInterval(35)
    while process.isRunning && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    precondition(!process.isRunning, "Helper timed out")
    return Result(status: process.terminationStatus,
                  output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                  error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
func call(_ arguments: [String], _ input: Data? = nil) -> Result { finish(launch(arguments, input)) }
func expect(_ result: Result, _ status: Int32, _ reason: String) {
    precondition(result.status == status, "\(reason): expected \(status), got \(result.status), \(result.error)")
}
func prepare() -> String {
    let result = call(["prepare"])
    expect(result, 0, "prepare")
    precondition(UUID(uuidString: result.output) != nil)
    return result.output
}
func replace(_ token: String, _ bytes: Data = Data("**Markdown**\n".utf8)) {
    expect(call(["replace", token], bytes), 0, "replace")
}
func write(_ contents: [[String: Data]]) {
    let objects = contents.map { formats -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, bytes) in formats { precondition(item.setData(bytes, forType: NSPasteboard.PasteboardType(type))) }
        return item
    }
    board.clearContents()
    if !objects.isEmpty { precondition(board.writeObjects(objects), "Private pasteboard unavailable: run outside sandbox") }
}
// Dieser Leser teilt keinen Capture-Code mit dem Produkt.
func readRaw() -> [[String: Data]] {
    // Auch ältere AppKit-Versionen sollen vor dem unabhängigen Lesen den
    // Eigentümerwechsel sehen, statt den lokal zwischengespeicherten Stand.
    _ = board.changeCount
    return (board.pasteboardItems ?? []).map { item in
        var result: [String: Data] = [:]
        for type in item.types {
            guard let bytes = item.data(forType: type) else { fatalError("Unmaterializable type in independent reader") }
            result[type.rawValue] = Data(Array(bytes))
        }
        return result
    }
}
func unchanged(_ count: Int, _ expected: [[String: Data]]) {
    precondition(board.changeCount == count, "Rejected request changed ownership")
    precondition(readRaw() == expected, "Rejected request changed content")
}
func pause(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}
func stop() { _ = call(["stop"]) }
defer { stop(); board.releaseGlobally() }
expect(call(["available"]), 0, "available without clipboard reads")
precondition(!FileManager.default.fileExists(atPath: service), "available created state")
expect(call(["undo"]), 1, "no undo state")

let original: [[String: Data]] = [
    ["public.utf8-plain-text": Data("Grüße\nFORMAT_SENTINEL_dab787ee".utf8),
     "public.html": Data("<b>Grüße</b>".utf8),
     "public.rtf": Data("{\\rtf1\\ansi Grüße}".utf8),
     "public.png": Data([137, 80, 78, 71, 0, 255, 128, 10]),
     "org.example.md-clip.binary": Data([0, 255, 128, 10])],
    ["org.example.md-clip.empty": Data(), "org.example.md-clip.second": Data([1, 2, 3])]
]
write(original)
let raw = readRaw()
precondition(raw.count == 2)
for (index, item) in original.enumerated() { for (type, bytes) in item { precondition(raw[index][type] == bytes) } }
let token = prepare()
let before = board.changeCount
expect(call(["cancel", UUID().uuidString]), 1, "wrong cancel token")
expect(call(["replace", UUID().uuidString], Data("wrong".utf8)), 1, "wrong replace token")
unchanged(before, raw)
replace(token)
precondition(board.string(forType: .string) == "**Markdown**\n")
expect(call(["undo"]), 0, "undo")
precondition(readRaw() == raw, "Full-format undo differs from original")
let restored = board.changeCount
expect(call(["undo"]), 1, "once-only undo")
unchanged(restored, raw)
print("PASS: 2 Items, HTML/RTF/Bild/custom/binär/leer bytegenau; Token und einmaliges Undo")

write([])
let emptyToken = prepare()
replace(emptyToken)
expect(call(["undo"]), 0, "empty clipboard undo")
precondition(readRaw().isEmpty)
print("PASS: leeres Clipboard wiederhergestellt")

write(original)
let changedToken = prepare()
write([["public.utf8-plain-text": Data("NEW COPY".utf8)]])
let copyCount = board.changeCount, newCopy = readRaw()
expect(call(["replace", changedToken], Data("must not replace".utf8)), 1, "changed since prepare")
unchanged(copyCount, newCopy)

write(original)
replace(prepare())
let markdown = readRaw()
write(markdown)
let sameCount = board.changeCount
expect(call(["undo"]), 1, "same bytes new ownership")
unchanged(sameCount, markdown)
print("PASS: neue Eigentümerschaft verwirft prepare/undo auch bei identischen Bytes")

write(original)
let first = launch(["prepare"]), second = launch(["prepare"])
let a = finish(first), b = finish(second)
precondition([a.status, b.status].sorted() == [0, 1], "Concurrent prepare must have one winner")
expect(call(["cancel", a.status == 0 ? a.output : b.output]), 0, "cancel winner")
replace(prepare())
let next = prepare()
expect(call(["prepare"]), 1, "busy prepare")
expect(call(["cancel", next]), 0, "cancel leaves previous undo")
expect(call(["undo"]), 0, "failed subsequent prepare preserves undo")
precondition(readRaw() == raw)
print("PASS: gleichzeitiges prepare, cancel und bestehendes Undo nach abgelehntem prepare")

final class Provider: NSObject, NSPasteboardItemDataProvider {
    enum Mode { case missing, mutate, delayed }
    let mode: Mode
    var calls = 0
    init(_ mode: Mode) { self.mode = mode }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        calls += 1
        switch mode {
        case .missing: break
        case .mutate:
            write([["public.utf8-plain-text": Data("NEW OWNER".utf8)]])
            _ = item.setData(Data("OLD OWNER".utf8), forType: type)
        case .delayed:
            Thread.sleep(forTimeInterval: 3)
            _ = item.setData(Data("late".utf8), forType: type)
        }
    }
}
func writeProvider(_ provider: Provider) {
    let item = NSPasteboardItem()
    precondition(item.setString("readable", forType: .string))
    precondition(item.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType("org.example.md-clip.promised")]))
    board.clearContents()
    precondition(board.writeObjects([item]))
}
let missing = Provider(.missing)
writeProvider(missing)
let missingCount = board.changeCount
expect(call(["prepare"]), 1, "missing provider data")
precondition(missing.calls > 0 && board.changeCount == missingCount)
precondition(board.string(forType: .string) == "readable")
let changing = Provider(.mutate)
writeProvider(changing)
expect(call(["prepare"]), 1, "ownership during read")
precondition(changing.calls > 0 && board.string(forType: .string) == "NEW OWNER")
print("PASS: nicht materialisierbarer Typ und Eigentümerwechsel während Materialisierung")

for type in ["Apple files promise pasteboard type", "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type"] {
    if type == "Apple files promise pasteboard type" {
        let legacy = NSPasteboard.PasteboardType(type)
        board.declareTypes([legacy], owner: nil)
        precondition(board.setData(Data("readable descriptor".utf8), forType: legacy))
    } else {
        write([[type: Data("readable descriptor".utf8)]])
    }
    let count = board.changeCount, expected = readRaw()
    expect(call(["prepare"]), 1, "file promise")
    unchanged(count, expected)
}
write([["public.file-url": Data("file:///tmp/materialized-file".utf8)]])
let fileURL = readRaw()
replace(prepare())
expect(call(["undo"]), 0, "materialized file URL")
precondition(readRaw() == fileURL)
print("PASS: Dateiversprechen abgelehnt, materialisierte Datei-URL erhalten")

var types: [String: Data] = [:]
for index in 0..<129 { types["org.example.md-clip.type\(index)"] = Data([UInt8(index)]) }
write([types])
let excessiveCount = board.changeCount, excessive = readRaw()
expect(call(["prepare"]), 1, "129 formats")
unchanged(excessiveCount, excessive)
types.removeValue(forKey: "org.example.md-clip.type128")
for _ in 0..<10 {
    write([types])
    let maximumTypes = readRaw()
    // Im Grenzfall getrennt erfassen, was ein zweiter Prozess tatsächlich sieht.
    let peerCapture = call(["--worker"], Data("{\"command\":\"capture\"}".utf8))
    expect(peerCapture, 0, "independent capture process")
    let peerReply = try! JSONSerialization.jsonObject(with: Data(peerCapture.output.utf8)) as! [String: Any]
    let peerItems = (peerReply["snapshot"] as! [String: Any])["items"] as! [[Any]]
    let peerCount = peerItems.reduce(0) { $0 + $1.count }
    replace(prepare())
    expect(call(["undo"]), 0, "128 formats exact limit")
    let restoredTypes = readRaw()
    if restoredTypes != maximumTypes {
        print("128 format mismatch: local source", maximumTypes.first?.count ?? 0,
              "peer capture", peerCount, "restored", restoredTypes.first?.count ?? 0)
        for key in Set(maximumTypes.first?.keys.map { $0 } ?? []).union(restoredTypes.first?.keys.map { $0 } ?? []) {
            let before = maximumTypes.first?[key], after = restoredTypes.first?[key]
            if before != after { print("Mismatch", key, before?.count ?? -1, after?.count ?? -1) }
        }
    }
    precondition(restoredTypes == maximumTypes)
}
write([["org.example.md-clip.large": Data(repeating: 255, count: 64 * 1024 * 1024 + 1)]])
let largeCount = board.changeCount
expect(call(["prepare"]), 1, "over 64 MiB")
precondition(board.changeCount == largeCount)
write([["org.example.md-clip.large": Data(repeating: 255, count: 64 * 1024 * 1024)]])
let maxToken = prepare()
replace(maxToken)
expect(call(["undo"]), 0, "64 MiB exact limit including base64 slashes")
precondition(readRaw().first?["org.example.md-clip.large"]?.count == 64 * 1024 * 1024)
print("PASS: 128-Format- und 64-MiB-Grenzen; genau 64 MiB erhalten")

let files = try! FileManager.default.contentsOfDirectory(atPath: service)
precondition(Set(files) == Set(["service.sock", "service.lock"]))
let attributes = try! FileManager.default.attributesOfItem(atPath: service)
precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o700)
let socketAttributes = try! FileManager.default.attributesOfItem(atPath: service + "/service.sock")
precondition((socketAttributes[.posixPermissions] as! NSNumber).intValue == 0o600)
precondition((try! Data(contentsOf: URL(fileURLWithPath: service + "/service.lock"))).isEmpty)
print("PASS: keine Inhaltsdateien; Dienstordner0700 und Socket0600")
stop()
environment["MD_CLIP_TEST_PENDING_TTL"] = "1"
write(original)
let expiringPending = prepare()
let pendingCount = board.changeCount
pause(1.4)
expect(call(["replace", expiringPending], Data("expired".utf8)), 1, "expired pending snapshot")
unchanged(pendingCount, raw)
print("PASS: abgelaufenes prepare schreibt nichts")
stop()
environment.removeValue(forKey: "MD_CLIP_TEST_PENDING_TTL")
environment["MD_CLIP_TEST_TTL"] = "1"
write(original)
replace(prepare())
let expiryCount = board.changeCount, expiryRaw = readRaw()
pause(1.4)
expect(call(["undo"]), 1, "expired undo")
unchanged(expiryCount, expiryRaw)
print("PASS: abgelaufene Sicherung entfernt ohne Clipboard-Schreiben")
stop()
environment["MD_CLIP_TEST_WORKER_SECONDS"] = "1"
let delayed = Provider(.delayed)
writeProvider(delayed)
let delayedCount = board.changeCount
let timed = launch(["prepare"])
let started = Date()
expect(finish(timed), 1, "blocking provider deadline")
precondition(delayed.calls > 0 && board.changeCount == delayedCount)
precondition(Date().timeIntervalSince(started) < 6, "Blocking read did not return promptly")
precondition(board.string(forType: .string) == "readable")
print("PASS: blockierter Format-Provider mit Worker-Frist abgebrochen")
stop()
pause(0.1)
environment.removeValue(forKey: "MD_CLIP_TEST_WORKER_SECONDS")
environment.removeValue(forKey: "MD_CLIP_TEST_TTL")
let directService = launch(["--serve"])
let socketDeadline = Date().addingTimeInterval(3)
while !FileManager.default.fileExists(atPath: service + "/service.sock") && Date() < socketDeadline { pause(0.02) }
precondition(directService.0.isRunning)
write(original)
replace(prepare())
let signalCount = board.changeCount, signalRaw = readRaw()
kill(directService.0.processIdentifier, SIGTERM)
expect(finish(directService), 0, "daemon SIGTERM")
unchanged(signalCount, signalRaw)
expect(call(["undo"]), 1, "SIGTERM discarded RAM snapshot")
precondition(!FileManager.default.fileExists(atPath: service + "/service.sock"))
print("PASS: SIGTERM verwirft RAM-Sicherung und Socket ohne Clipboard-Schreiben")

let unsafe = root + "/unsafe"
try! FileManager.default.createDirectory(atPath: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
environment["MD_CLIP_TEST_DIRECTORY"] = unsafe
expect(call(["available"]), 2, "unsafe directory")
expect(call(["prepare"]), 2, "unsafe directory prepare")
let symlink = root + "/linked"
try! FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: service)
environment["MD_CLIP_TEST_DIRECTORY"] = symlink
expect(call(["prepare"]), 2, "symlink service directory")
print("PASS: unsicherer Dienstordner und Symlink abgelehnt")
print("Alle privaten macOS-Undo-Tests erfolgreich.")
