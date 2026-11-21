import AppKit
import Foundation

@main
struct ClipboardUndoTestMain {
    @MainActor
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory =
            try environment["MD_CLIP_TEST_DIRECTORY"] ?? UndoConfiguration.defaultServiceDirectory()
        let name = NSPasteboard.Name(
            environment["MD_CLIP_TEST_PASTEBOARD"] ?? "org.md-clip.test-unused.\(UUID())"
        )
        precondition(name != NSPasteboard.Name.general)
        let gatePath = environment["MD_CLIP_TEST_REPLY_GATE"]
        ClipboardUndo.run(
            configuration: UndoConfiguration(
                serviceDirectory: directory,
                pasteboardName: name,
                workerSeconds: Double(environment["MD_CLIP_TEST_WORKER_SECONDS"] ?? "") ?? 24,
                pendingSeconds: Double(environment["MD_CLIP_TEST_PENDING_TTL"] ?? "") ?? 600,
                undoSeconds: Double(environment["MD_CLIP_TEST_TTL"] ?? "") ?? 600,
                beforeServiceReply: gatePath.map { path in
                    {
                        let files = FileManager.default
                        guard files.fileExists(atPath: path) else { return }
                        precondition(files.createFile(atPath: path + ".ready", contents: nil))
                        let deadline = ProcessInfo.processInfo.systemUptime + 5
                        while files.fileExists(atPath: path) {
                            precondition(ProcessInfo.processInfo.systemUptime < deadline,
                                         "Test did not release the reply gate")
                            usleep(1_000)
                        }
                    }
                }
            ))
    }
}
