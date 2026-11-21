import Foundation

enum UpdaterMode: String {
    case background = "--background"
    case interactive = "--interactive"

    static func parse(arguments: [String]) -> Self {
        let usage = "Aufruf: md-clip-updater --background | --interactive"
        guard arguments.count == 2 else { fail(usage) }
        guard let mode = Self(rawValue: arguments[1]) else {
            fail("Unbekannte Option: \(arguments[1])\n\(usage)")
        }
        return mode
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(64)
    }
}
