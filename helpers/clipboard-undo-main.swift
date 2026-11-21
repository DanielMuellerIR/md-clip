@main
struct ClipboardUndoMain {
    @MainActor
    static func main() {
        ClipboardUndo.run()
    }
}
