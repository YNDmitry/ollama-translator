import AppKit
import ApplicationServices
import Carbon

struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
}

struct CapturedSelection {
    let text: String?
    let savedClipboard: PasteboardSnapshot?
    let usedClipboard: Bool
    let usedAutoSelectAll: Bool
    let autoSelectTooLong: Bool
}

@MainActor
enum TextAutomation {
    static let maxAutoSelectLength = 8000

    static func isAccessibilityGranted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func snapshotPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            if !dict.isEmpty {
                savedItems.append(dict)
            }
        }
        return PasteboardSnapshot(items: savedItems)
    }

    static func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }

        var pbItems: [NSPasteboardItem] = []
        for dict in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            pbItems.append(item)
        }
        pb.writeObjects(pbItems)
    }

    /// Reads currently selected text in the frontmost app.
    /// If `allowAutoSelectAll` is true and nothing is selected, automatically selects all (Cmd+A) in the focused input field.
    static func captureSelectedText(allowAutoSelectAll: Bool = false) async -> CapturedSelection {
        // 1. Try instant AXSelectedText first (no clipboard flicker)
        if let axText = readSelectedTextViaAccessibility(),
           !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CapturedSelection(
                text: axText,
                savedClipboard: nil,
                usedClipboard: false,
                usedAutoSelectAll: false,
                autoSelectTooLong: false
            )
        }

        // 2. Fallback: wait briefly for hotkey modifiers to release, then send Cmd+C
        await waitForModifiersRelease(maxWaitMs: 420)

        let pb = NSPasteboard.general
        let saved = snapshotPasteboard()
        let beforeCount = pb.changeCount

        sendCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_C))

        var copied: String?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != beforeCount {
                copied = pb.string(forType: .string)
                break
            }
        }

        if let copied = copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CapturedSelection(
                text: copied,
                savedClipboard: saved,
                usedClipboard: true,
                usedAutoSelectAll: false,
                autoSelectTooLong: false
            )
        }

        // 3. Auto-select entire input field (Cmd+A -> Cmd+C) when nothing was selected
        if allowAutoSelectAll {
            let beforeSelectAllCount = pb.changeCount
            sendCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_A))
            try? await Task.sleep(nanoseconds: 55_000_000)
            sendCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_C))

            var allCopied: String?
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if pb.changeCount != beforeSelectAllCount {
                    allCopied = pb.string(forType: .string)
                    break
                }
            }

            if let text = allCopied, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if text.count > maxAutoSelectLength {
                    // Safety guard: avoid replacing an entire huge document or webpage
                    return CapturedSelection(
                        text: nil,
                        savedClipboard: saved,
                        usedClipboard: true,
                        usedAutoSelectAll: true,
                        autoSelectTooLong: true
                    )
                }
                return CapturedSelection(
                    text: text,
                    savedClipboard: saved,
                    usedClipboard: true,
                    usedAutoSelectAll: true,
                    autoSelectTooLong: false
                )
            }
        }

        return CapturedSelection(
            text: nil,
            savedClipboard: saved,
            usedClipboard: true,
            usedAutoSelectAll: false,
            autoSelectTooLong: false
        )
    }

    /// Replaces currently selected text (or pastes at cursor) in the target app.
    static func replaceSelectedText(
        with newText: String,
        restoreClipboard: Bool,
        existingSnapshot: PasteboardSnapshot? = nil,
        targetApp: NSRunningApplication? = nil
    ) async {
        if let app = targetApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate(options: [])
            try? await Task.sleep(nanoseconds: 90_000_000)
        }

        await waitForModifiersRelease(maxWaitMs: 300)

        let pb = NSPasteboard.general
        let snapshotToRestore = existingSnapshot ?? (restoreClipboard ? snapshotPasteboard() : nil)

        pb.clearContents()
        pb.setString(newText, forType: .string)
        let changeCountAfterSet = pb.changeCount

        try? await Task.sleep(nanoseconds: 35_000_000)
        sendCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_V))

        if restoreClipboard, let snapshot = snapshotToRestore {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if pb.changeCount == changeCountAfterSet {
                restorePasteboard(snapshot)
            }
        }
    }

    private static func readSelectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppObj) == .success,
              let focusedApp = focusedAppObj else {
            return nil
        }

        var focusedElemObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElemObj) == .success,
              let focusedElem = focusedElemObj else {
            return nil
        }

        var selectedTextObj: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(focusedElem as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextObj)
        if status == .success, let str = selectedTextObj as? String, !str.isEmpty {
            return str
        }
        return nil
    }

    private static func waitForModifiersRelease(maxWaitMs: Int) async {
        let mask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let steps = max(1, maxWaitMs / 15)
        for _ in 0..<steps {
            let flags = CGEventSource.flagsState(.hidSystemState)
            if flags.intersection(mask).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private static func sendCommandShortcut(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .privateState) else { return }

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        cmdDown?.flags = .maskCommand

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        cmdUp?.flags = []

        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
