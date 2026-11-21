import AppKit
import ApplicationServices
import Carbon
import Foundation

guard CommandLine.arguments.count >= 2,
      let pid = pid_t(CommandLine.arguments[1]), pid > 0 else { exit(64) }
func keyCode(for character: String) -> CGKeyCode? {
    guard let input = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let property = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return nil }
    return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
        for code in UInt16(0)..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var result = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, result.count, &length, &result)
            if status == noErr && String(utf16CodeUnits: result, count: length) == character {
                return code
            }
        }
        return nil
    }
}

if CommandLine.arguments.count >= 3 && CommandLine.arguments[2] == "post-key" {
    guard CommandLine.arguments.count == 5,
          let code = CGKeyCode(CommandLine.arguments[3]) ?? keyCode(for: CommandLine.arguments[3]),
          ["command", "none"].contains(CommandLine.arguments[4]),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          CGPreflightPostEventAccess(),
          let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else { exit(5) }
    if CommandLine.arguments[4] == "command" {
        down.flags = .maskCommand
        up.flags = .maskCommand
    }
    down.postToPid(pid)
    Thread.sleep(forTimeInterval: 0.05)
    up.postToPid(pid)
    exit(0)
}

let application = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(application, 1)

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
}
func text(_ element: AXUIElement, _ attribute: String) -> String {
    value(element, attribute) as? String ?? ""
}
func fields(_ element: AXUIElement) -> [String: Any] {
    var result: [String: Any] = ["role": text(element, "AXRole"), "name": text(element, "AXTitle"),
        "description": text(element, "AXDescription"), "identifier": text(element, "AXIdentifier")]
    for attribute in ["AXEnabled", "AXFocused", "AXValue", "AXSelectedText"] {
        if let content = value(element, attribute) as? String { result[attribute] = String(content.prefix(4096)) }
        else if let number = value(element, attribute) as? NSNumber { result[attribute] = number }
    }
    if let selected = value(element, "AXSelectedTextRange"), CFGetTypeID(selected) == AXValueGetTypeID() {
        var range = CFRange()
        if AXValueGetValue(selected as! AXValue, .cfRange, &range) { result["range"] = [range.location, range.length] }
    }
    return result
}

var seen: [AXUIElement] = []
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    // AX ist ein Graph. Wiederholte Elemente dürfen keine rekursive Endlosschleife bilden.
    guard depth < 24, !seen.contains(where: { CFEqual($0, element) }) else { return [] }
    seen.append(element)
    let children = value(element, "AXChildren") as? [AXUIElement] ?? []
    return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}
let windows = value(application, "AXWindows") as? [AXUIElement] ?? []
let elements = windows.flatMap { descendants($0) }
if CommandLine.arguments.count >= 3 && CommandLine.arguments[2] == "focus" {
    guard CommandLine.arguments.count == 4 else { exit(64) }
    let target = CommandLine.arguments[3]
    guard let element = elements.first(where: {
        text($0, "AXIdentifier") == target || text($0, "AXDescription") == target || text($0, "AXTitle") == target
    }) else { exit(2) }
    guard AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue) == .success else { exit(3) }
}
var result: [String: Any] = ["elements": elements.map { fields($0) }]
if let focused = value(application, "AXFocusedUIElement"), CFGetTypeID(focused) == AXUIElementGetTypeID() {
    result["focused"] = fields(focused as! AXUIElement)
}
do {
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
} catch { exit(4) }
