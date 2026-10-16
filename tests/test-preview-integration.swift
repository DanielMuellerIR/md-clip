import AppKit
import Foundation
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
enum Check: Error { case failed(String) }
func require(_ value: Bool, _ message: String) throws { if !value { throw Check.failed(message) } }
let helper = CommandLine.arguments[1], cli = CommandLine.arguments[2], root = CommandLine.arguments[3]
let ui = CommandLine.arguments.dropFirst(4).contains("--ui")
let board = NSPasteboard.withUniqueName()
let observed = root + "/observed.json", action = root + "/action"
var environment = ProcessInfo.processInfo.environment
environment["MD_CLIP_TEST_PASTEBOARD"] = board.name.rawValue
environment["MD_CLIP_TEST_DIRECTORY"] = root + "/service"
environment["MD_CLIP_TEST_PREVIEW_BACKGROUND"] = "1"
environment["MD_CLIP_TEST_PREVIEW_EVIDENCE"] = observed
environment["MD_CLIP_TEST_PREVIEW_ACTION"] = action
environment["MD_CLIP_TEST_IO_PID"] = root + "/io.pid"
environment["PATH"] = URL(fileURLWithPath: cli).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
for key in ["MD_CLIP_TEST_TTL", "MD_CLIP_TEST_PENDING_TTL", "MD_CLIP_TEST_WORKER_SECONDS"] { environment.removeValue(forKey: key) }
var children: [Process] = []
struct Running { let process: Process; let output: Pipe; let error: Pipe; let writer: DispatchGroup }
struct Result { let status: Int32; let output: Data; let error: String }
func pause(_ seconds: Double) {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}
func stop(_ process: Process) {
    if process.isRunning { process.terminate() }
    let end = ProcessInfo.processInfo.systemUptime + 3
    while process.isRunning && ProcessInfo.processInfo.systemUptime < end { pause(0.01) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}
func launch(_ executable: String, _ arguments: [String], _ data: Data? = nil, heldInput: Pipe? = nil) throws -> Running {
    let process = Process(), output = Pipe(), error = Pipe(), writer = DispatchGroup()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments; process.environment = environment
    process.standardOutput = output; process.standardError = error
    if let input = heldInput {
        process.standardInput = input; try process.run()
    } else if let data {
        let input = Pipe(); process.standardInput = input
        try process.run()
        writer.enter()
        DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
            writer.leave()
        }
    } else { process.standardInput = FileHandle.nullDevice; try process.run() }
    children.append(process)
    return Running(process: process, output: output, error: error, writer: writer)
}
func finish(_ running: Running) throws -> Result {
    let end = ProcessInfo.processInfo.systemUptime + 35
    while running.process.isRunning && ProcessInfo.processInfo.systemUptime < end { pause(0.01) }
    if running.process.isRunning { stop(running.process); throw Check.failed("Prozess-Zeitlimit") }
    try require(running.writer.wait(timeout: .now() + 1) == .success, "stdin-Writer blieb aktiv")
    return Result(status: running.process.terminationStatus, output: running.output.fileHandleForReading.readDataToEndOfFile(),
                  error: String(decoding: running.error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
func call(_ arguments: [String], _ data: Data? = nil) throws -> Result { try finish(launch(helper, arguments, data)) }
func expect(_ result: Result, _ status: Int32, _ reason: String) throws {
    try require(result.status == status, "\(reason): Exit \(result.status), erwartet \(status): \(result.error)")
}
func token() throws -> String {
    let result = try call(["prepare"]); try expect(result, 0, "prepare")
    return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
}
func raw() -> [[String: Data]] {
    return (board.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
    }
}
func write(_ data: String) throws {
    board.clearContents(); try require(board.setString(data, forType: .string), "Testdaten nicht schreibbar")
}
func seed(_ previous: Bool) throws -> [[String: Data]] {
    _ = try? call(["stop"])
    let item = NSPasteboardItem(), other = NSPasteboardItem()
    item.setString("Original ä😀\n", forType: .string)
    item.setData(Data("<b>Original</b>".utf8), forType: .html)
    item.setData(Data([0, 255, 1, 2]), forType: NSPasteboard.PasteboardType("org.example.md-clip.binary"))
    other.setString("Zweites Item", forType: .string)
    board.clearContents(); try require(board.writeObjects([item, other]), "Originale nicht schreibbar")
    let original = raw()
    if previous { try expect(call(["replace", token()], Data("previous".utf8)), 0, "vorige Ersetzung") }
    return original
}
let options = ["--stdin", "--plain", "--replace", "--preview-window", "--quiet"]
let body = Data("# Ergebnis ä😀\n\n```sh\nprintf '%s' \\\n  '\\# unverändert'\n```\n\n".utf8)
func startPreview() throws -> Running {
    try? FileManager.default.removeItem(atPath: observed)
    try? FileManager.default.removeItem(atPath: action)
    return try launch(cli, options, body)
}
func observation(_ running: Running, _ predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
    let end = ProcessInfo.processInfo.systemUptime + 15
    while ProcessInfo.processInfo.systemUptime < end {
        if !running.process.isRunning { let result = try finish(running); throw Check.failed("Vorschau endete: \(result.status), \(result.error)") }
        if let bytes = FileManager.default.contents(atPath: observed),
           let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            try require(value["visible"] as? Bool == true, "Fenster nicht sichtbar")
            try require(value["front_pid"] as? Int != value["preview_pid"] as? Int, "Vorschau nahm Vordergrund-Fokus")
            if predicate(value) { return value }
        }
        pause(0.02)
    }
    throw Check.failed("Vorschauzustand nicht erreicht")
}
func click(_ name: String) throws { try Data(name.utf8).write(to: URL(fileURLWithPath: action), options: .atomic) }
func cliUndo(_ original: [[String: Data]]) throws {
    let result = try finish(launch(cli, ["--undo", "--quiet"]))
    try expect(result, 0, "CLI-Undo"); try require(result.output.isEmpty && raw() == original, "Undo-Formatbytes unterscheiden sich")
}
func run() throws {
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer {
        for child in children where child.isRunning { stop(child) }
        _ = try? call(["stop"])
        board.releaseGlobally()
    }
    for (bytes, label) in [(Data([255]), "ungültiges UTF-8"), (Data(repeating: 97, count: 64 * 1024 * 1024 + 1), "Größenlimit")] {
        let original = try seed(true), before = raw(), count = board.changeCount
        let result = try finish(launch(cli, options, bytes))
        try expect(result, 3, label)
        try require(result.output.isEmpty && raw() == before && board.changeCount == count, "Abgelehnte Vorschau änderte Clipboard")
        try cliUndo(original)
    }
    let rtfOriginal = try seed(true), rtfBefore = raw(), rtfCount = board.changeCount
    let invalidRTF = try finish(launch(cli, ["--stdin", "--from", "rtf", "--replace", "--preview-window", "--quiet"], Data("plain tagged as RTF".utf8)))
    try expect(invalidRTF, 3, "falsche RTF-Quelle")
    try require(invalidRTF.output.isEmpty && invalidRTF.error.contains("RTF-Kopf") && raw() == rtfBefore && board.changeCount == rtfCount, "Falsche RTF-Quelle änderte Clipboard oder fehlender Grund")
    try cliUndo(rtfOriginal)
    for interruption in [SIGINT, SIGTERM] {
        let original = try seed(true), previous = raw(), count = board.changeCount
        let input = Pipe(), marker = environment["MD_CLIP_TEST_IO_PID"]!
        try? FileManager.default.removeItem(atPath: marker)
        let running = try launch(cli, ["--stdin", "--plain", "--replace", "--quiet"], heldInput: input)
        defer { try? input.fileHandleForWriting.close() }
        let end = ProcessInfo.processInfo.systemUptime + 8
        while !FileManager.default.fileExists(atPath: marker) && running.process.isRunning && ProcessInfo.processInfo.systemUptime < end { pause(0.01) }
        guard let bytes = FileManager.default.contents(atPath: marker),
              let identifier = Int32(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Check.failed("stdin-Kindprozess nicht erreicht") }
        kill(running.process.processIdentifier, interruption)
        try expect(finish(running), interruption == SIGINT ? 130 : 143, "Parent-only stdin-Signal ohne EOF")
        try require(kill(identifier, 0) != 0 && errno == ESRCH, "stdin-Kindprozess blieb aktiv")
        try require(raw() == previous && board.changeCount == count, "Signal änderte Clipboard")
        try expect(call(["cancel", token()]), 0, "Signal storniert vorbereiteten Token")
        try cliUndo(original)
    }
    print("OK: Parent-only INT/TERM beendet offene stdin-Kopie ohne EOF und erhält vollständiges natives Undo")
    let original = try seed(true), before = raw(), count = board.changeCount
    let resource = URL(fileURLWithPath: cli).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("helpers/md-clip-preview").path
    try FileManager.default.moveItem(atPath: resource, toPath: resource + ".hidden")
    do {
        let result = try finish(launch(cli, options, body)); try expect(result, 2, "fehlende Ressource")
        try require(raw() == before && board.changeCount == count, "Fehlende Ressource änderte Clipboard")
    } catch { try? FileManager.default.moveItem(atPath: resource + ".hidden", toPath: resource); throw error }
    try FileManager.default.moveItem(atPath: resource + ".hidden", toPath: resource)
    try cliUndo(original)
    print("OK: echte CLI und nativer Undo-Dienst schützen Formate/Undo bei RTF-, UTF-8-, Größen- und Ressourcenfehlern ohne GUI")
    if !ui { return }

    let acceptedOriginal = try seed(false)
    let accept = try startPreview()
    _ = try observation(accept) { $0["accept"] as? Bool == true && $0["undo"] as? Bool == false }
    try click("accept"); let accepted = try finish(accept); try expect(accepted, 0, "Übernehmen")
    try require(accepted.output.isEmpty && board.data(forType: .string) == body, "Übernommene Bytes unterscheiden sich")
    try cliUndo(acceptedOriginal)
    print("OK: echte CLI und native Übernahme schreiben exakt einmaliges Ergebnis; vollständiges CLI-Undo")

    for decision in ["cancel", "undo"] {
        let original = try seed(true), previous = raw(), count = board.changeCount
        let running = try startPreview()
        _ = try observation(running) { $0["accept"] as? Bool == true && $0["undo"] as? Bool == true }
        try click(decision); let result = try finish(running); try expect(result, decision == "cancel" ? 4 : 0, decision)
        try require(result.output.isEmpty, "UI-Aktion schrieb Nutzdaten nach stdout")
        if decision == "cancel" {
            try require(raw() == previous && board.changeCount == count, "Abbruch änderte Clipboard")
            try cliUndo(original)
        } else {
            try require(raw() == original, "Vorschau-Undo restaurierte nicht alle Formate")
            try expect(finish(launch(cli, ["--undo", "--quiet"])), 1, "Undo bleibt einmalig")
        }
    }
    print("OK: echte native Abbruch-/Undo-Aktionen erhalten Clipboard und vorige Sicherung")

    _ = try seed(false)
    let changed = try startPreview()
    _ = try observation(changed) { $0["accept"] as? Bool == true }
    try write("external"); let external = raw(), externalCount = board.changeCount
    _ = try observation(changed) { $0["accept"] as? Bool == false }
    try click("accept"); pause(1.3)
    try require(changed.process.isRunning, "Ungültige Übernahme beendete Vorschau")
    try click("cancel"); try expect(finish(changed), 4, "Abbruch nach Kopieren")
    try require(raw() == external && board.changeCount == externalCount, "Neues Kopieren überschrieben")
    print("OK: echte Generationänderung deaktiviert Übernahme und schützt neue Bytes")

    let signalOriginal = try seed(true)
    let interrupted = try startPreview()
    let value = try observation(interrupted) { $0["accept"] as? Bool == true }
    interrupted.process.terminate(); try expect(finish(interrupted), 143, "TERM")
    guard let identifier = value["preview_pid"] as? Int, identifier > 0 else { throw Check.failed("Vorschau-PID fehlt") }
    let previewPID = pid_t(identifier)
    try require(kill(previewPID, 0) != 0 && errno == ESRCH, "Vorschauprozess blieb nach TERM aktiv")
    let next = try token(); try expect(call(["cancel", next]), 0, "TERM storniert Vorbereitung")
    try cliUndo(signalOriginal)
    print("OK: echte CLI-Signalbehandlung beendet native Vorschau, storniert Token und erhält voriges Undo")
}
func servePrivateBoard() throws {
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer {
        for child in children where child.isRunning { stop(child) }
        _ = try? call(["stop"])
        board.releaseGlobally()
    }
    func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    func snapshot() -> [String: Any] {
        let items = raw().map { item in item.mapValues { $0.base64EncodedString() } }
        return ["items": items, "change_count": board.changeCount,
                "host_change_count": NSPasteboard.general.changeCount]
    }
    try emit(["board": board.name.rawValue, "directory": environment["MD_CLIP_TEST_DIRECTORY"]!])
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = command["operation"] as? String else { throw Check.failed("Ungültiger Prüfauftrag") }
        switch operation {
        case "seed":
            environment["MD_CLIP_TEST_PENDING_TTL"] = String(command["pending_seconds"] as? Int ?? 600)
            environment["MD_CLIP_TEST_TTL"] = String(command["undo_seconds"] as? Int ?? 600)
            let original = try seed(command["previous"] as? Bool ?? false)
            var result = snapshot()
            result["original"] = original.map { $0.mapValues { $0.base64EncodedString() } }
            try emit(result)
        case "write":
            try write(command["text"] as? String ?? "Neue private Kopie")
            try emit(snapshot())
        case "snapshot": try emit(snapshot())
        case "undo":
            let result = try finish(launch(cli, ["--undo", "--quiet"]))
            var value = snapshot(); value["exit"] = Int(result.status); value["error"] = result.error
            try emit(value)
        case "stop": try emit(snapshot()); return
        default: throw Check.failed("Unbekannter Prüfauftrag")
        }
    }
}

do {
    if CommandLine.arguments.dropFirst(4).contains("--serve-private-board") {
        try servePrivateBoard()
    } else { try run() }
}
catch { fputs("Native Vorschauintegration fehlgeschlagen: \(error)\n", stderr); exit(1) }
