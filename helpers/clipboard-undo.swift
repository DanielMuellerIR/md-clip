import AppKit
import Foundation
import UniformTypeIdentifiers
import Darwin

// Versprochene Pasteboard-Daten können fremden Code blockieren. Nur kurzlebige
// Worker berühren die Nutzdaten; der Dienst hält die Sicherung ausschließlich im RAM.
private let maximumBytes = 64 * 1024 * 1024
private let maximumWireBytes = 96 * 1024 * 1024
private let requestSeconds: Double = 28
private let workerSeconds: Double = {
#if TEST
    return Double(ProcessInfo.processInfo.environment["MD_CLIP_TEST_WORKER_SECONDS"] ?? "24") ?? 24
#else
    return 24
#endif
}()
private let pendingSeconds: Double = {
#if TEST
    return Double(ProcessInfo.processInfo.environment["MD_CLIP_TEST_PENDING_TTL"] ?? "600") ?? 600
#else
    return 600
#endif
}()
private let undoSeconds: Double = {
#if TEST
    return Double(ProcessInfo.processInfo.environment["MD_CLIP_TEST_TTL"] ?? "600") ?? 600
#else
    return 600
#endif
}()
private var serviceDirectory: String {
#if TEST
    if let value = ProcessInfo.processInfo.environment["MD_CLIP_TEST_DIRECTORY"] { return value }
#endif
    return "/private/tmp/md-clip-undo-\(getuid())"
}
private var pasteboard: NSPasteboard {
#if TEST
    if let name = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PASTEBOARD"] {
        return NSPasteboard(name: NSPasteboard.Name(name))
    }
#endif
    return .general
}
private let socketPath = serviceDirectory + "/service.sock"
private let executableURL = Bundle.main.executableURL!
private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(value)
}
private struct Failure: Error { let status: Int; let message: String }
private func fail(_ status: Int, _ message: String) -> Failure { Failure(status: status, message: message) }
private struct Format: Codable { let type: String; let bytes: Data }
private struct Snapshot: Codable { let count: Int; let items: [[Format]] }
private struct Request: Codable { let command: String; var token: String?; var bytes: Data?; var snapshot: Snapshot?; var count: Int? }
private struct Reply: Codable { var status: Int; var message: String?; var token: String?; var snapshot: Snapshot?; var count: Int? }
private func checkDirectory(create: Bool) throws {
    if create && mkdir(serviceDirectory, 0o700) != 0 && errno != EEXIST {
        throw fail(2, "Der private Undo-Dienstordner konnte nicht angelegt werden.")
    }
    var info = stat()
    guard lstat(serviceDirectory, &info) == 0,
          info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
          info.st_mode & 0o777 == 0o700 else {
        throw fail(2, "Der Undo-Dienstordner ist nicht sicher zugänglich.")
    }
}
private func checkSocket() throws {
    var info = stat()
    guard lstat(socketPath, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o777 == 0o600 else {
        throw fail(2, "Der Undo-Dienstsocket ist nicht sicher zugänglich.")
    }
}
private func socketAddress() throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw fail(2, "Der Undo-Dienstpfad ist zu lang.") }
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}
private func makeSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw fail(2, "Der Undo-Dienstsocket konnte nicht angelegt werden.") }
    var enabled: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    return fd
}
private func ready(_ fd: Int32, _ events: Int16, _ deadline: Double) throws {
    while true {
        let remaining = deadline - now()
        guard remaining > 0 else { throw fail(1, "Die Undo-Anfrage hat das Zeitlimit überschritten.") }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
        if result > 0 { return }
        if result < 0 && errno != EINTR { throw fail(1, "Die Undo-Verbindung wurde unterbrochen.") }
    }
}
private func readBytes(_ fd: Int32, count: Int, deadline: Double) throws -> Data {
    var result = Data(count: count)
    var offset = 0
    while offset < count {
        try ready(fd, Int16(POLLIN), deadline)
        let size = result.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
        if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard size > 0 else { throw fail(1, "Die Undo-Verbindung wurde unterbrochen.") }
        offset += size
    }
    return result
}
private func sendBytes(_ fd: Int32, _ bytes: Data, deadline: Double) throws {
    var offset = 0
    while offset < bytes.count {
        try ready(fd, Int16(POLLOUT), deadline)
        let size = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
        if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard size > 0 else { throw fail(1, "Die Undo-Verbindung wurde unterbrochen.") }
        offset += size
    }
}
private func receive<T: Decodable>(_ fd: Int32, deadline: Double) throws -> T {
    let header = try readBytes(fd, count: 4, deadline: deadline)
    let size = header.reduce(0) { ($0 << 8) | Int($1) }
    guard size > 0 && size <= maximumWireBytes else { throw fail(1, "Die Undo-Anfrage ist zu groß oder ungültig.") }
    do { return try JSONDecoder().decode(T.self, from: readBytes(fd, count: size, deadline: deadline)) }
    catch let error as Failure { throw error }
    catch { throw fail(1, "Die Undo-Anfrage ist ungültig.") }
}
private func transmit<T: Encodable>(_ fd: Int32, _ value: T, deadline: Double) throws {
    let bytes = try encode(value)
    guard bytes.count <= maximumWireBytes else { throw fail(1, "Die Undo-Anfrage ist zu groß.") }
    let size = UInt32(bytes.count)
    let header = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
    try sendBytes(fd, header, deadline: deadline)
    try sendBytes(fd, bytes, deadline: deadline)
}
private func capture() throws -> Snapshot {
    let board = pasteboard
    let count = board.changeCount
    let items = board.pasteboardItems ?? []
    var totalBytes = 0
    var totalTypes = 0
    var contents: [[Format]] = []
    for item in items {
        let types = item.types
        guard !types.isEmpty else { throw fail(1, "Ein Clipboard-Element bietet keine sicherbaren Formate an.") }
        // Dateiversprechen enthalten nur Provider-Beschreibungen, keine vollständigen
        // Dateidaten. Ihr ausführbarer Provider lässt sich aus Rohbytes nicht retten.
        let filePromises: Set<String> = ["Apple files promise pasteboard type", "NSFilesPromisePboardType",
            "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type"]
        guard !types.contains(where: { type in
            if filePromises.contains(type.rawValue) { return true }
            // AppKit bildet ältere Pasteboard-Namen auf dynamische UTIs ab.
            let aliases = UTType(type.rawValue)?.tags[UTTagClass(rawValue: "com.apple.nspboard-type")] ?? []
            return aliases.contains(where: { filePromises.contains($0) })
        }) else {
            throw fail(1, "Das Clipboard enthält ein Dateiversprechen, das nicht vollständig gesichert werden kann.")
        }
        totalTypes += types.count
        guard totalTypes <= 128 else { throw fail(1, "Das Clipboard enthält mehr als 128 Formate.") }
        var formats: [Format] = []
        for type in types {
            guard board.changeCount == count else { throw fail(1, "Das Clipboard wurde während der Sicherung geändert.") }
            guard type.rawValue.utf8.count <= 4096, let bytes = item.data(forType: type) else { throw fail(1, "Ein Clipboard-Format konnte nicht vollständig gelesen werden.") }
            guard board.changeCount == count else { throw fail(1, "Das Clipboard wurde während der Sicherung geändert.") }
            guard bytes.count <= maximumBytes - totalBytes else { throw fail(1, "Das Clipboard ist größer als 64 MiB.") }
            totalBytes += bytes.count
            // Keine Pasteboard-/Provider-Puffer über einen Eigentümerwechsel behalten.
            let ownedBytes = bytes.isEmpty ? Data() : bytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
            formats.append(Format(type: type.rawValue, bytes: ownedBytes))
        }
        contents.append(formats)
    }
    guard board.changeCount == count else { throw fail(1, "Das Clipboard wurde während der Sicherung geändert.") }
    return Snapshot(count: count, items: contents)
}
private func materializedItem(_ formats: [Format]) throws -> NSPasteboardItem {
    // Native Items tragen alle Formatbytes schon vor dem Schreiben. Der
    // kurzlebige Worker darf keine Datenlieferung nach seinem Ende benötigen.
    let item = NSPasteboardItem()
    for format in formats {
        guard item.setData(format.bytes, forType: NSPasteboard.PasteboardType(format.type)) else {
            throw fail(3, "Ein Clipboard-Format konnte nicht vollständig vorbereitet werden.")
        }
    }
    return item
}
private func writeClipboard(_ request: Request) throws -> Int {
    let board = pasteboard
    guard let expected = request.count else { throw fail(1, "Der Clipboard-Zustand fehlt.") }
    let contents: [[Format]]
    if request.command == "replace" {
        guard let bytes = request.bytes, bytes.count <= maximumBytes,
              String(data: bytes, encoding: .utf8) != nil else { throw fail(1, "Der Ersatztext ist kein gültiger UTF-8-Text oder zu groß.") }
        contents = [[Format(type: NSPasteboard.PasteboardType.string.rawValue, bytes: bytes)]]
    } else {
        guard let snapshot = request.snapshot else { throw fail(1, "Die Clipboard-Sicherung fehlt.") }
        contents = snapshot.items
    }
    let objects = try contents.map { try materializedItem($0) }
    // NSPasteboard bietet keine atomare compare-and-swap-Operation. Der letzte
    // Zählervergleich liegt unmittelbar vor clearContents; diese kleine Lücke bleibt.
    guard board.changeCount == expected else { throw fail(1, "Das Clipboard wurde inzwischen geändert; Undo ist nicht mehr verfügbar.") }
    let writtenCount = board.clearContents()
    if !objects.isEmpty && !board.writeObjects(objects) { throw fail(3, "Das Clipboard konnte nicht vollständig geschrieben werden.") }
    guard board.changeCount == writtenCount else { throw fail(1, "Das Clipboard wurde während des Schreibens geändert; Undo ist nicht mehr verfügbar.") }
    // AppKit kann die Veröffentlichung nach writeObjects noch vervollständigen.
    // Ein eigener Leser sieht dabei bereits lokale Puffer. Ein zweiter Prozess
    // muss deshalb alle Bytes bestätigen, während der Writer seine RunLoop bedient.
    let confirmation = try withExtendedLifetime(objects) {
        try runWorker(Request(command: "capture"), pumpRunLoop: true)
    }
    guard confirmation.status == 0, let published = confirmation.snapshot else {
        throw fail(3, confirmation.message ?? "Die Clipboard-Veröffentlichung konnte nicht bestätigt werden.")
    }
    let expectedFormats = contents.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.type, $0.bytes) }) }
    let actual = published.items.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.type, $0.bytes) }) }
    guard published.count == writtenCount, actual == expectedFormats else { throw fail(3, "Das Clipboard wurde nicht vollständig veröffentlicht.") }
    return writtenCount
}
private func worker() {
    do {
        let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let reply: Reply
        if request.command == "capture" { reply = Reply(status: 0, snapshot: try capture()) }
        else { reply = Reply(status: 0, count: try writeClipboard(request)) }
        FileHandle.standardOutput.write(try encode(reply))
    } catch let error as Failure {
        if let bytes = try? encode(Reply(status: error.status, message: error.message)) { FileHandle.standardOutput.write(bytes) }
    } catch {
        if let bytes = try? encode(Reply(status: 1, message: "Die Clipboard-Anfrage konnte nicht verarbeitet werden.")) { FileHandle.standardOutput.write(bytes) }
    }
}
private final class WorkerOutput: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var tooLarge = false
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count > maximumWireBytes - data.count { tooLarge = true }
        else if !tooLarge { data.append(bytes) }
    }
}
private func runWorker(_ request: Request, pumpRunLoop: Bool = false) throws -> Reply {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--worker"]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let bytes = try encode(request)
    let collector = WorkerOutput()
    let group = DispatchGroup()
    try process.run()
    group.enter()
    DispatchQueue.global().async {
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            collector.append(data)
        }
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        // Ein vorzeitig beendeter Worker darf keinen SIGPIPE im Dienst auslösen.
        try? input.fileHandleForWriting.write(contentsOf: bytes)
        try? input.fileHandleForWriting.close()
        group.leave()
    }
    let deadline = now() + workerSeconds
    while process.isRunning && now() < deadline && requestedStop == 0 {
        // Nur der Writer muss AppKit-Datenanfragen des Bestätigungslesers bedienen.
        if pumpRunLoop { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        else { usleep(10_000) }
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 1)
        throw fail(1, "Ein Clipboard-Format hat das Zeitlimit überschritten; das Clipboard bleibt unverändert, sofern noch kein Schreiben begonnen hatte.")
    }
    guard group.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0,
          !collector.tooLarge else { throw fail(1, "Der Clipboard-Worker konnte nicht abgeschlossen werden.") }
    do { return try JSONDecoder().decode(Reply.self, from: collector.data) }
    catch { throw fail(1, "Der Clipboard-Worker lieferte kein vollständiges Ergebnis.") }
}
private var requestedStop: sig_atomic_t = 0
private func handleSignal(_ signal: Int32) { requestedStop = 1 }
private func serve() throws {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM, handleSignal)
    signal(SIGINT, handleSignal)
    try checkDirectory(create: true)
    let lockPath = serviceDirectory + "/service.lock"
    let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw fail(2, "Die Undo-Dienstsperre ist nicht zugänglich.") }
    defer { close(lock) }
    var info = stat()
    guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o777 == 0o600 else { throw fail(2, "Die Undo-Dienstsperre ist unsicher.") }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
    if lstat(socketPath, &info) == 0 {
        try checkSocket()
        guard unlink(socketPath) == 0 else { throw fail(2, "Der alte Undo-Dienstsocket konnte nicht entfernt werden.") }
    }
    let listener = try makeSocket()
    defer { close(listener); unlink(socketPath) }
    var address = try socketAddress()
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 8) == 0 else { throw fail(2, "Der Undo-Dienst konnte nicht gestartet werden.") }
    var pending: (token: String, snapshot: Snapshot, expires: Double)?
    var committed: (snapshot: Snapshot, count: Int, expires: Double)?
    var idleSince = now()
    var hadSnapshot = false
    while requestedStop == 0 {
        let clock = now()
        if let entry = pending, clock >= entry.expires { pending = nil }
        if let entry = committed, clock >= entry.expires { committed = nil }
        if pending != nil || committed != nil {
            let count = pasteboard.changeCount
            if let entry = pending, count != entry.snapshot.count { pending = nil }
            if let entry = committed, count != entry.count { committed = nil }
            idleSince = clock
        } else if clock - idleSince > 600 { break }
        // Nach Ablauf, Verbrauch oder Verwerfen auch den Prozess beenden: frühere
        // Clipboard-Bytes bleiben damit nicht im freigegebenen Heap des Dienstes.
        if hadSnapshot && pending == nil && committed == nil && clock - idleSince > 0.5 { break }
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 250) <= 0 { continue }
        let fd = accept(listener, nil, nil)
        if fd < 0 { continue }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let deadline = now() + requestSeconds
        var reply: Reply
        do {
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { throw fail(2, "Der Undo-Client gehört einem anderen Benutzer.") }
            let request: Request = try receive(fd, deadline: deadline)
            switch request.command {
            case "prepare":
                guard pending == nil else { throw fail(1, "Eine Clipboard-Sicherung ist bereits in Vorbereitung.") }
                let result = try runWorker(Request(command: "capture"))
                guard result.status == 0, let snapshot = result.snapshot else { throw fail(result.status == 0 ? 1 : result.status, result.message ?? "Das Clipboard konnte nicht gesichert werden.") }
                guard pasteboard.changeCount == snapshot.count else { throw fail(1, "Das Clipboard wurde während der Sicherung geändert.") }
                let token = UUID().uuidString
                pending = (token, snapshot, now() + pendingSeconds)
                hadSnapshot = true
                reply = Reply(status: 0, token: token)
            case "cancel":
                guard let entry = pending, entry.token == request.token else { throw fail(1, "Die vorbereitete Clipboard-Sicherung ist nicht mehr verfügbar.") }
                pending = nil
                reply = Reply(status: 0)
            case "replace":
                guard let entry = pending, entry.token == request.token, now() < entry.expires else { throw fail(1, "Die vorbereitete Clipboard-Sicherung ist nicht mehr verfügbar.") }
                pending = nil
                let result = try runWorker(Request(command: "replace", bytes: request.bytes, count: entry.snapshot.count))
                guard result.status == 0, let count = result.count else { throw fail(result.status == 0 ? 1 : result.status, result.message ?? "Das Clipboard konnte nicht ersetzt werden.") }
                committed = (entry.snapshot, count, now() + undoSeconds)
                reply = Reply(status: 0)
            case "undo":
                guard let entry = committed, now() < entry.expires else { throw fail(1, "Undo ist nicht mehr verfügbar.") }
                committed = nil
                pending = nil
                let result = try runWorker(Request(command: "restore", snapshot: entry.snapshot, count: entry.count))
                guard result.status == 0 else { throw fail(result.status, result.message ?? "Das Clipboard konnte nicht wiederhergestellt werden.") }
                reply = Reply(status: 0)
            case "stop":
                pending = nil; committed = nil; requestedStop = 1
                reply = Reply(status: 0)
            default: throw fail(1, "Der Undo-Befehl ist ungültig.")
            }
        } catch let error as Failure { reply = Reply(status: error.status, message: error.message) }
        catch { reply = Reply(status: 2, message: "Der Undo-Dienst konnte die Anfrage nicht verarbeiten.") }
        try? transmit(fd, reply, deadline: deadline)
        close(fd)
        idleSince = now()
    }
}
private func connectService() throws -> Int32 {
    var info = stat()
    guard lstat(serviceDirectory, &info) == 0 else {
        if errno == ENOENT { throw fail(1, "Undo ist nicht mehr verfügbar.") }
        throw fail(2, "Der Undo-Dienstordner ist nicht zugänglich.")
    }
    try checkDirectory(create: false)
    guard lstat(socketPath, &info) == 0 else {
        if errno == ENOENT { throw fail(1, "Undo ist nicht mehr verfügbar.") }
        throw fail(2, "Der Undo-Dienstsocket ist nicht zugänglich.")
    }
    try checkSocket()
    let fd = try makeSocket()
    var address = try socketAddress()
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if result != 0 { close(fd); throw fail(1, "Der Undo-Dienst ist nicht verfügbar.") }
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); throw fail(2, "Der Undo-Dienst gehört einem anderen Benutzer.") }
    return fd
}
private func serviceExists() -> Bool {
    var info = stat()
    return lstat(serviceDirectory, &info) == 0
}
private func stdinBytes(deadline: Double) throws -> Data {
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        try ready(STDIN_FILENO, Int16(POLLIN), deadline)
        let size = read(STDIN_FILENO, &buffer, buffer.count)
        if size == 0 { return bytes }
        if size < 0 && errno == EINTR { continue }
        guard size > 0, size <= maximumBytes - bytes.count else { throw fail(1, "Der Ersatztext ist größer als 64 MiB oder nicht lesbar.") }
        bytes.append(contentsOf: buffer.prefix(size))
    }
}
private func client() throws -> Reply {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first, ["prepare", "replace", "cancel", "undo", "available", "stop"].contains(command),
          arguments.count == ((command == "replace" || command == "cancel") ? 2 : 1) else { throw fail(2, "Aufruf: clipboard-undo prepare | replace TOKEN | cancel TOKEN | undo | available | stop") }
    if command == "available" {
        if serviceExists() { try checkDirectory(create: false) }
        _ = try socketAddress()
        return Reply(status: 0)
    }
    let deadline = now() + requestSeconds
    var request = Request(command: command, token: arguments.count == 2 ? arguments[1] : nil)
    if command == "replace" { request.bytes = try stdinBytes(deadline: deadline) }
    var fd: Int32
    do { fd = try connectService() }
    catch {
        guard command == "prepare" else { throw error }
        try checkDirectory(create: true)
        // Ein vorhandener unsicherer Socket wird niemals durch einen Neustart ersetzt.
        var info = stat()
        if lstat(socketPath, &info) == 0 { try checkSocket() }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--serve"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var connected: Int32?
        let startupDeadline = min(deadline, now() + 3)
        while now() < startupDeadline {
            if let candidate = try? connectService() { connected = candidate; break }
            if !process.isRunning { break }
            usleep(20_000)
            // Das gesamte Starten bleibt durch die äußere Frist begrenzt.
        }
        guard let connected else { throw fail(2, "Der Undo-Dienst konnte nicht gestartet werden.") }
        fd = connected
    }
    defer { close(fd) }
    try transmit(fd, request, deadline: deadline)
    return try receive(fd, deadline: deadline)
}
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.dropFirst().first == "--worker" { worker(); exit(0) }
do {
    if CommandLine.arguments.dropFirst().first == "--serve" { try serve(); exit(0) }
    let reply = try client()
    if let token = reply.token { print(token) }
    if let message = reply.message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    exit(Int32(reply.status))
} catch let error as Failure {
    FileHandle.standardError.write(Data((error.message + "\n").utf8)); exit(Int32(error.status))
} catch {
    FileHandle.standardError.write(Data("Der Undo-Helfer konnte nicht gestartet werden.\n".utf8)); exit(2)
}
