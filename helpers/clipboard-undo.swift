import AppKit
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

// Versprochene Pasteboard-Daten können fremden Code blockieren. Nur kurzlebige
// Worker berühren die Nutzdaten; der Dienst hält die Sicherung ausschließlich im RAM.
private let maximumBytes = 64 * 1024 * 1024
private let maximumWireBytes = 96 * 1024 * 1024
private let requestSeconds: Double = 28
struct UndoConfiguration {
    let serviceDirectory: String
    var pasteboardName: NSPasteboard.Name? = nil
    var workerSeconds: Double = 24
    var pendingSeconds: Double = 600
    var undoSeconds: Double = 600
    var beforeServiceReply: (() -> Void)? = nil

    static func defaultServiceDirectory() throws -> String {
        // Anders als TMPDIR liefert confstr App und CLI denselben Benutzerordner.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else {
            throw fail(2, "Das private macOS-Temporärverzeichnis ist nicht verfügbar.")
        }
        var path = [CChar](repeating: 0, count: length)
        let directory = path.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let start = buffer.baseAddress,
                confstr(_CS_DARWIN_USER_TEMP_DIR, start, buffer.count) == length
            else { return nil }
            return String(validatingCString: start)
        }
        guard let directory, directory.hasPrefix("/") else {
            throw fail(2, "Das private macOS-Temporärverzeichnis ist nicht verfügbar.")
        }
        return URL(fileURLWithPath: directory).appendingPathComponent("md-clip-undo").path
    }
}

private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(value)
}
private struct Failure: Error {
    let status: Int
    let message: String
}
private func fail(_ status: Int, _ message: String) -> Failure { Failure(status: status, message: message) }
private struct Format: Codable {
    let type: String
    let bytes: Data
}

private struct PasteboardRead<Value: Codable>: Codable {
    let count: Int
    let items: [Value]
}

private typealias Snapshot = PasteboardRead<[Format]>
private typealias Confirmation = PasteboardRead<[String: Data]>

private struct Request: Codable {
    let command: String
    var token: String?
    var bytes: Data?
    var snapshot: Snapshot?
    var count: Int?
}

private struct Reply: Codable {
    var status: Int
    var message: String?
    var token: String?
    var snapshot: Snapshot?
    var count: Int?
    var confirmation: Confirmation?
    var undoAvailable: Bool?
    var pendingValid: Bool?
}

private struct UndoStatus: Encodable {
    var version = 1
    var undo_available: Bool
    var pending_valid: Bool
}

private final class ServiceStop: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool { lock.withLock { requested } }

    func request() {
        lock.withLock { requested = true }
    }
}

struct ClipboardUndo {
    private let configuration: UndoConfiguration
    private var serviceDirectory: String { configuration.serviceDirectory }
    private var socketPath: String { serviceDirectory + "/service.sock" }

    @MainActor
    private var pasteboard: NSPasteboard {
        if let name = configuration.pasteboardName { return NSPasteboard(name: name) }
        return .general
    }

    private func childProcess(arguments: [String]) throws -> Process {
        guard let executableURL = Bundle.main.executableURL else {
            throw fail(2, "Der Undo-Helfer konnte nicht gefunden werden.")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        return process
    }

    private func checkDirectory(create: Bool) throws {
        if create && mkdir(serviceDirectory, 0o700) != 0 && errno != EEXIST {
            throw fail(2, "Der private Undo-Dienstordner konnte nicht angelegt werden.")
        }
        var info = stat()
        guard lstat(serviceDirectory, &info) == 0,
            info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
            info.st_mode & 0o777 == 0o700
        else {
            throw fail(2, "Der Undo-Dienstordner ist nicht sicher zugänglich.")
        }
    }
    private func checkSocket() throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o777 == 0o600
        else {
            throw fail(2, "Der Undo-Dienstsocket ist nicht sicher zugänglich.")
        }
    }
    private func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw fail(2, "Der Undo-Dienstpfad ist zu lang.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    private func configureSocket(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            && fcntl(fd, F_SETFL, O_NONBLOCK) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }
    private func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail(2, "Der Undo-Dienstsocket konnte nicht angelegt werden.") }
        guard configureSocket(fd) else {
            close(fd)
            throw fail(2, "Der Undo-Dienstsocket konnte nicht eingerichtet werden.")
        }
        return fd
    }
    private func ready(_ fd: Int32, _ events: Int16, _ deadline: Double, stop: ServiceStop? = nil) throws {
        while true {
            guard stop?.isRequested != true else { throw fail(1, "Der Undo-Dienst wurde beendet.") }
            let remaining = deadline - now()
            guard remaining > 0 else { throw fail(1, "Die Undo-Anfrage hat das Zeitlimit überschritten.") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, max(1, Int32(min(remaining * 1000, 250))))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw fail(1, "Die Undo-Verbindung wurde unterbrochen.") }
        }
    }
    private func readBytes(_ fd: Int32, count: Int, deadline: Double, stop: ServiceStop?) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try ready(fd, Int16(POLLIN), deadline, stop: stop)
            let size = result.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return read(fd, base.advanced(by: offset), count - offset)
            }
            if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard size > 0 else { throw fail(1, "Die Undo-Verbindung wurde unterbrochen.") }
            offset += size
        }
        return result
    }
    private func sendBytes(_ fd: Int32, _ bytes: Data, deadline: Double, stop: ServiceStop?) throws {
        var offset = 0
        while offset < bytes.count {
            try ready(fd, Int16(POLLOUT), deadline, stop: stop)
            let size = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard size > 0 else { throw fail(1, "Die Undo-Verbindung wurde unterbrochen.") }
            offset += size
        }
    }
    private func receive<T: Decodable>(_ fd: Int32, deadline: Double, stop: ServiceStop? = nil) throws -> T
    {
        let header = try readBytes(fd, count: 4, deadline: deadline, stop: stop)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0 && size <= maximumWireBytes else {
            throw fail(1, "Die Undo-Anfrage ist zu groß oder ungültig.")
        }
        do {
            return try JSONDecoder().decode(
                T.self, from: readBytes(fd, count: size, deadline: deadline, stop: stop))
        } catch let error as Failure { throw error } catch {
            throw fail(1, "Die Undo-Anfrage ist ungültig.")
        }
    }
    private func transmit<T: Encodable>(_ fd: Int32, _ value: T, deadline: Double, stop: ServiceStop? = nil)
        throws
    {
        let bytes = try encode(value)
        guard bytes.count <= maximumWireBytes else { throw fail(1, "Die Undo-Anfrage ist zu groß.") }
        let size = UInt32(bytes.count)
        let header = Data([
            UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255),
        ])
        try sendBytes(fd, header, deadline: deadline, stop: stop)
        try sendBytes(fd, bytes, deadline: deadline, stop: stop)
    }
    @MainActor
    private func readPasteboard<Value: Codable>(
        using: (String, Data, inout Value) -> Void,
        startingWith: () -> Value
    ) throws -> PasteboardRead<Value> {
        let board = pasteboard
        let count = board.changeCount
        let items = board.pasteboardItems ?? []
        var totalBytes = 0
        var totalTypes = 0
        var contents: [Value] = []
        for item in items {
            let types = item.types
            guard !types.isEmpty else {
                throw fail(1, "Ein Clipboard-Element bietet keine sicherbaren Formate an.")
            }
            // Dateiversprechen enthalten nur Provider-Beschreibungen, keine vollständigen
            // Dateidaten. Ihr ausführbarer Provider lässt sich aus Rohbytes nicht retten.
            let filePromises: Set<String> = [
                "Apple files promise pasteboard type", "NSFilesPromisePboardType",
                "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type",
            ]
            guard
                !types.contains(where: { type in
                    if filePromises.contains(type.rawValue) { return true }
                    // AppKit bildet ältere Pasteboard-Namen auf dynamische UTIs ab.
                    let aliases =
                        UTType(type.rawValue)?.tags[UTTagClass(rawValue: "com.apple.nspboard-type")] ?? []
                    return aliases.contains(where: { filePromises.contains($0) })
                })
            else {
                throw fail(
                    1,
                    "Das Clipboard enthält ein Dateiversprechen, das nicht vollständig gesichert werden kann."
                )
            }
            totalTypes += types.count
            guard totalTypes <= 128 else { throw fail(1, "Das Clipboard enthält mehr als 128 Formate.") }
            var formats = startingWith()
            var seen = Set<String>()
            for type in types {
                guard seen.insert(type.rawValue).inserted else {
                    throw fail(1, "Ein Clipboard-Element bietet denselben Formatnamen mehrfach an.")
                }
                guard board.changeCount == count else {
                    throw fail(1, "Das Clipboard wurde während der Sicherung geändert.")
                }
                guard type.rawValue.utf8.count <= 4096, let bytes = item.data(forType: type) else {
                    throw fail(1, "Ein Clipboard-Format konnte nicht vollständig gelesen werden.")
                }
                guard board.changeCount == count else {
                    throw fail(1, "Das Clipboard wurde während der Sicherung geändert.")
                }
                guard bytes.count <= maximumBytes - totalBytes else {
                    throw fail(1, "Das Clipboard ist größer als 64 MiB.")
                }
                totalBytes += bytes.count
                using(type.rawValue, bytes, &formats)
            }
            contents.append(formats)
        }
        guard board.changeCount == count else {
            throw fail(1, "Das Clipboard wurde während der Sicherung geändert.")
        }
        return PasteboardRead(count: count, items: contents)
    }
    @MainActor
    private func capture() throws -> Snapshot {
        try readPasteboard(
            using: { type, bytes, formats in
                // Keine Pasteboard-/Provider-Puffer über einen Eigentümerwechsel behalten.
                let ownedBytes = bytes.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return Data() }
                    return Data(bytes: base, count: buffer.count)
                }
                formats.append(Format(type: type, bytes: ownedBytes))
            }, startingWith: { [] })
    }

    @MainActor
    private func confirmPublication() throws -> Confirmation {
        try readPasteboard(
            using: { type, bytes, digests in
                digests[type] = Data(SHA256.hash(data: bytes))
            }, startingWith: { [:] })
    }

    @MainActor
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
    @MainActor
    private func writeClipboard(_ request: Request) throws -> Int {
        let board = pasteboard
        guard let expected = request.count else { throw fail(1, "Der Clipboard-Zustand fehlt.") }
        let contents: [[Format]]
        if request.command == "replace" {
            guard let bytes = request.bytes, bytes.count <= maximumBytes,
                String(data: bytes, encoding: .utf8) != nil
            else { throw fail(1, "Der Ersatztext ist kein gültiger UTF-8-Text oder zu groß.") }
            contents = [[Format(type: NSPasteboard.PasteboardType.string.rawValue, bytes: bytes)]]
        } else {
            guard let snapshot = request.snapshot else { throw fail(1, "Die Clipboard-Sicherung fehlt.") }
            contents = snapshot.items
        }
        let expectedDigests = try contents.map { formats in
            var digests: [String: Data] = [:]
            for format in formats {
                guard digests[format.type] == nil else {
                    throw fail(1, "Die Clipboard-Sicherung enthält doppelte Formatnamen.")
                }
                digests[format.type] = Data(SHA256.hash(data: format.bytes))
            }
            return digests
        }
        let objects = try contents.map { try materializedItem($0) }
        // NSPasteboard bietet keine atomare compare-and-swap-Operation. Der letzte
        // Zählervergleich liegt unmittelbar vor clearContents; diese kleine Lücke bleibt.
        guard board.changeCount == expected else {
            throw fail(1, "Das Clipboard wurde inzwischen geändert; Undo ist nicht mehr verfügbar.")
        }
        let writtenCount = board.clearContents()
        if !objects.isEmpty && !board.writeObjects(objects) {
            throw fail(3, "Das Clipboard konnte nicht vollständig geschrieben werden.")
        }
        guard board.changeCount == writtenCount else {
            throw fail(
                1, "Das Clipboard wurde während des Schreibens geändert; Undo ist nicht mehr verfügbar.")
        }
        // AppKit kann die Veröffentlichung nach writeObjects noch vervollständigen.
        // Ein eigener Leser sieht dabei bereits lokale Puffer. Ein zweiter Prozess
        // muss deshalb alle Bytes bestätigen, während der Writer seine RunLoop bedient.
        let confirmation = try withExtendedLifetime(objects) {
            try runWorker(Request(command: "confirm"), pumpRunLoop: true)
        }
        guard confirmation.status == 0, let published = confirmation.confirmation else {
            throw fail(
                3, confirmation.message ?? "Die Clipboard-Veröffentlichung konnte nicht bestätigt werden.")
        }
        guard published.count == writtenCount, published.items == expectedDigests,
            board.changeCount == writtenCount
        else {
            throw fail(3, "Das Clipboard wurde nicht vollständig veröffentlicht.")
        }
        return writtenCount
    }

    @MainActor
    private func worker() throws {
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        let reply: Reply
        switch request.command {
        case "confirm":
            reply = Reply(status: 0, confirmation: try confirmPublication())
        case "capture":
            reply = Reply(status: 0, snapshot: try capture())
        case "replace", "restore":
            reply = Reply(status: 0, count: try writeClipboard(request))
        default:
            throw fail(1, "Der Undo-Befehl ist ungültig.")
        }
        FileHandle.standardOutput.write(try encode(reply))
    }

    private final class WorkerOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var tooLarge = false

        func append(_ bytes: Data) {
            lock.withLock {
                guard !tooLarge else { return }
                if bytes.count > maximumWireBytes - data.count {
                    tooLarge = true
                    data = Data()
                } else {
                    data.append(bytes)
                }
            }
        }

        func result() throws -> Data {
            try lock.withLock {
                guard !tooLarge else { throw fail(1, "Das Ergebnis des Clipboard-Workers ist zu groß.") }
                return data
            }
        }
    }

    @MainActor
    private func runWorker(
        _ request: Request, pumpRunLoop: Bool = false, stop: ServiceStop? = nil
    ) throws -> Reply {
        let process = try childProcess(arguments: ["--worker", String(getpid())])
        let input = Pipe()
        let output = Pipe()
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
        let deadline = now() + configuration.workerSeconds
        while process.isRunning && now() < deadline && stop?.isRequested != true {
            // Nur der Writer muss AppKit-Datenanfragen des Bestätigungslesers bedienen.
            if pumpRunLoop {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            } else {
                usleep(10_000)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            _ = group.wait(timeout: .now() + 1)
            throw fail(
                1,
                "Ein Clipboard-Format hat das Zeitlimit überschritten; das Clipboard bleibt unverändert, sofern noch kein Schreiben begonnen hatte."
            )
        }
        guard group.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else {
            throw fail(1, "Der Clipboard-Worker konnte nicht abgeschlossen werden.")
        }
        do { return try JSONDecoder().decode(Reply.self, from: collector.result()) } catch {
            throw fail(1, "Der Clipboard-Worker lieferte kein vollständiges Ergebnis.")
        }
    }

    @MainActor
    private func serve() throws {
        let stop = ServiceStop()
        let sources = [SIGTERM, SIGINT].map { value in
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global(qos: .userInitiated))
            source.setEventHandler { @Sendable in stop.request() }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }
        try checkDirectory(create: true)
        let lockPath = serviceDirectory + "/service.lock"
        let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw fail(2, "Die Undo-Dienstsperre ist nicht zugänglich.") }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
            info.st_mode & 0o777 == 0o600
        else { throw fail(2, "Die Undo-Dienstsperre ist unsicher.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        if lstat(socketPath, &info) == 0 {
            try checkSocket()
            guard unlink(socketPath) == 0 else {
                throw fail(2, "Der alte Undo-Dienstsocket konnte nicht entfernt werden.")
            }
        }
        let listener = try makeSocket()
        defer { close(listener) }
        var address = try socketAddress()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw fail(2, "Der Undo-Dienst konnte nicht gestartet werden.") }
        defer { unlink(socketPath) }
        guard chmod(socketPath, 0o600) == 0, listen(listener, 8) == 0 else {
            throw fail(2, "Der Undo-Dienst konnte nicht gestartet werden.")
        }
        var pending: (token: String, snapshot: Snapshot, expires: Double)?
        var committed: (snapshot: Snapshot, count: Int, expires: Double)?
        var idleSince = now()
        var hadSnapshot = false
        var stopping = false
        while !stopping && !stop.isRequested {
            let clock = now()
            if let entry = pending, clock >= entry.expires { pending = nil }
            if let entry = committed, clock >= entry.expires { committed = nil }
            if pending != nil || committed != nil {
                let count = pasteboard.changeCount
                if let entry = pending, count != entry.snapshot.count { pending = nil }
                if let entry = committed, count != entry.count { committed = nil }
                idleSince = clock
            } else if clock - idleSince > 600 {
                break
            }
            // Nach Ablauf, Verbrauch oder Verwerfen auch den Prozess beenden: frühere
            // Clipboard-Bytes bleiben damit nicht im freigegebenen Heap des Dienstes.
            if hadSnapshot && pending == nil && committed == nil && clock - idleSince > 0.5 { break }
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 250) <= 0 { continue }
            let fd = accept(listener, nil, nil)
            if fd < 0 { continue }
            defer { close(fd) }
            guard configureSocket(fd) else { continue }
            let deadline = now() + requestSeconds
            var reply: Reply
            var isStatus = false
            var preparedToken: String?
            do {
                var peerUID: uid_t = 0
                var peerGID: gid_t = 0
                guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                    throw fail(2, "Der Undo-Client gehört einem anderen Benutzer.")
                }
                let request: Request = try receive(fd, deadline: deadline, stop: stop)
                isStatus = request.command == "status"
                switch request.command {
                case "status":
                    let count = pasteboard.changeCount
                    if let entry = pending, now() >= entry.expires || count != entry.snapshot.count {
                        pending = nil
                    }
                    if let entry = committed, now() >= entry.expires || count != entry.count {
                        committed = nil
                    }
                    reply = Reply(
                        status: 0, undoAvailable: committed != nil,
                        pendingValid: pending != nil && pending?.token == request.token)
                case "prepare":
                    guard pending == nil else {
                        throw fail(1, "Eine Clipboard-Sicherung ist bereits in Vorbereitung.")
                    }
                    let result = try runWorker(Request(command: "capture"), stop: stop)
                    guard result.status == 0, let snapshot = result.snapshot else {
                        throw fail(
                            result.status == 0 ? 1 : result.status,
                            result.message ?? "Das Clipboard konnte nicht gesichert werden.")
                    }
                    guard pasteboard.changeCount == snapshot.count else {
                        throw fail(1, "Das Clipboard wurde während der Sicherung geändert.")
                    }
                    let token = UUID().uuidString
                    pending = (token, snapshot, now() + configuration.pendingSeconds)
                    preparedToken = token
                    hadSnapshot = true
                    reply = Reply(status: 0, token: token)
                case "cancel":
                    guard let entry = pending, entry.token == request.token else {
                        throw fail(1, "Die vorbereitete Clipboard-Sicherung ist nicht mehr verfügbar.")
                    }
                    pending = nil
                    reply = Reply(status: 0)
                case "replace":
                    guard let entry = pending, entry.token == request.token, now() < entry.expires else {
                        throw fail(1, "Die vorbereitete Clipboard-Sicherung ist nicht mehr verfügbar.")
                    }
                    pending = nil
                    let result = try runWorker(
                        Request(command: "replace", bytes: request.bytes, count: entry.snapshot.count),
                        stop: stop)
                    guard result.status == 0, let count = result.count else {
                        throw fail(
                            result.status == 0 ? 1 : result.status,
                            result.message ?? "Das Clipboard konnte nicht ersetzt werden.")
                    }
                    committed = (entry.snapshot, count, now() + configuration.undoSeconds)
                    reply = Reply(status: 0)
                case "undo":
                    guard let entry = committed, now() < entry.expires else {
                        throw fail(1, "Undo ist nicht mehr verfügbar.")
                    }
                    committed = nil
                    pending = nil
                    let result = try runWorker(
                        Request(command: "restore", snapshot: entry.snapshot, count: entry.count),
                        stop: stop)
                    guard result.status == 0 else {
                        throw fail(
                            result.status,
                            result.message ?? "Das Clipboard konnte nicht wiederhergestellt werden.")
                    }
                    reply = Reply(status: 0)
                case "stop":
                    pending = nil
                    committed = nil
                    stopping = true
                    reply = Reply(status: 0)
                default: throw fail(1, "Der Undo-Befehl ist ungültig.")
                }
            } catch let error as Failure {
                reply = Reply(status: error.status, message: error.message)
            } catch {
                reply = Reply(status: 2, message: "Der Undo-Dienst konnte die Anfrage nicht verarbeiten.")
            }
            configuration.beforeServiceReply?()
            do { try transmit(fd, reply, deadline: deadline, stop: stop) } catch {
                // Ohne übertragene Token-Antwort kann dieser Client nicht stornieren.
                if let token = preparedToken, pending?.token == token { pending = nil }
            }
            if !isStatus { idleSince = now() }
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
        var address = try socketAddress()
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(fd)
            throw fail(1, "Der Undo-Dienst ist nicht verfügbar.")
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            throw fail(2, "Der Undo-Dienst gehört einem anderen Benutzer.")
        }
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
            guard size > 0, size <= maximumBytes - bytes.count else {
                throw fail(1, "Der Ersatztext ist größer als 64 MiB oder nicht lesbar.")
            }
            bytes.append(contentsOf: buffer.prefix(size))
        }
    }
    private func client() throws -> Reply {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first,
            ["prepare", "replace", "cancel", "undo", "available", "diagnose", "status", "stop"].contains(
                command),
            command == "status"
                ? [1, 2].contains(arguments.count)
                : arguments.count == ((command == "replace" || command == "cancel") ? 2 : 1)
        else {
            throw fail(
                2,
                "Aufruf: clipboard-undo prepare | replace TOKEN | cancel TOKEN | undo | available | diagnose | status [TOKEN] | stop"
            )
        }
        if command == "diagnose" {
            if serviceExists() { try checkDirectory(create: false) }
            _ = try socketAddress()
            // Sitzungsmetadaten benötigen weder Pasteboard-Zugriff noch GUI-Start.
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let ready =
                session?[kCGSessionUserIDKey as String] as? Int == Int(getuid())
                && session?[kCGSessionOnConsoleKey as String] as? Bool == true
                && session?[kCGSessionLoginDoneKey as String] as? Bool == true
            print(ready ? "ok" : "macos-session-missing")
            return Reply(status: 0)
        }
        if command == "available" {
            if serviceExists() { try checkDirectory(create: false) }
            _ = try socketAddress()
            return Reply(status: 0)
        }
        let deadline = now() + requestSeconds
        var request = Request(command: command, token: arguments.count == 2 ? arguments[1] : nil)
        if command == "replace" { request.bytes = try stdinBytes(deadline: deadline) }
        var fd: Int32
        do { fd = try connectService() } catch {
            if command == "status", let failure = error as? Failure, failure.status == 1 {
                return Reply(status: 0, undoAvailable: false, pendingValid: false)
            }
            guard command == "prepare" else { throw error }
            try checkDirectory(create: true)
            // Ein vorhandener unsicherer Socket wird niemals durch einen Neustart ersetzt.
            var info = stat()
            if lstat(socketPath, &info) == 0 { try checkSocket() }
            let process = try childProcess(arguments: ["--serve"])
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            var connected: Int32?
            let startupDeadline = min(deadline, now() + 3)
            while now() < startupDeadline {
                if let candidate = try? connectService() {
                    connected = candidate
                    break
                }
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
    @MainActor
    static func run(configuration override: UndoConfiguration? = nil) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        do {
            let configuration =
                try override
                ?? UndoConfiguration(serviceDirectory: UndoConfiguration.defaultServiceDirectory())
            let command = ClipboardUndo(configuration: configuration)
            switch arguments.dropFirst().first {
            case "--serve":
                try command.serve()
                exit(0)
            case "--worker":
                guard arguments.count == 3, let parent = pid_t(arguments[2]), parent == getppid(),
                    parent > 1
                else {
                    exit(1)
                }
                // Ein blockierter AppKit-Worker darf nach Ende seines Auftraggebers nicht weiterleben.
                let watcher = DispatchSource.makeProcessSource(
                    identifier: parent, eventMask: .exit, queue: .global())
                watcher.setEventHandler { @Sendable in _exit(1) }
                watcher.resume()
                defer { watcher.cancel() }
                guard parent == getppid() else { exit(1) }
                do {
                    try command.worker()
                } catch let error as Failure {
                    FileHandle.standardOutput.write(
                        try encode(Reply(status: error.status, message: error.message)))
                } catch {
                    FileHandle.standardOutput.write(
                        try encode(
                            Reply(
                                status: 1, message: "Die Clipboard-Anfrage konnte nicht verarbeitet werden."
                            )))
                }
            default:
                let reply = try command.client()
                if arguments.dropFirst().first == "status" {
                    let state = UndoStatus(
                        undo_available: reply.undoAvailable ?? false,
                        pending_valid: reply.pendingValid ?? false)
                    FileHandle.standardOutput.write(try encode(state) + Data([10]))
                } else if let token = reply.token {
                    print(token)
                }
                if let message = reply.message {
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                }
                exit(Int32(reply.status))
            }
        } catch let error as Failure {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            exit(Int32(error.status))
        } catch {
            FileHandle.standardError.write(Data("Der Undo-Helfer konnte nicht gestartet werden.\n".utf8))
            exit(2)
        }
        exit(0)
    }
}
