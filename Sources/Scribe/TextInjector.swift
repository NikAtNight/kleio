// Ported from LocalFlow.
import AppKit
import Carbon.HIToolbox

/// Inserts text into the app that currently has focus.
@MainActor
enum TextInjector {
    // These values are confined to the main actor. They track a save and
    // restore cycle across dictations that overlap within the restore window.
    private static var savedItems: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?
    private static var pendingCompletion: (@MainActor @Sendable (Bool) -> Void)?
    private static var ourChangeCount = -1
    private static var restoreGeneration = 0

    /// Reports whether the paste is believed to have landed. A result is true
    /// when the clipboard was undisturbed through the restore window, or when
    /// secure-input typing finished successfully.
    static func inject(_ text: String, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard !text.isEmpty else {
            completion?(false)
            return
        }

        if IsSecureEventInputEnabled() {
            typeString(text, completion: completion)
            return
        }

        let pasteboard = NSPasteboard.general

        // Preserve the original clipboard across overlapping injections. A
        // new snapshot here could otherwise save a prior dictation instead.
        restoreWork?.cancel()
        restoreWork = nil
        restoreGeneration &+= 1
        if let pending = pendingCompletion {
            pendingCompletion = nil
            pending(pasteboard.changeCount == ourChangeCount)
        }
        if savedItems == nil || pasteboard.changeCount != ourChangeCount {
            savedItems = snapshot(of: pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ourChangeCount = pasteboard.changeCount
        guard postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            if let saved = savedItems {
                savedItems = nil
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
            completion?(false)
            return
        }
        pendingCompletion = completion

        // Apps service paste asynchronously. Wait for the paste to read the
        // injected clipboard contents before restoring the user's clipboard.
        let generation = restoreGeneration
        let work = DispatchWorkItem {
            guard generation == restoreGeneration else { return }
            restoreWork = nil
            let saved = savedItems
            savedItems = nil
            let completion = pendingCompletion
            pendingCompletion = nil
            let undisturbed = pasteboard.changeCount == ourChangeCount
            if undisturbed, let saved {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
            completion?(undisturbed)
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static let typingQueue = DispatchQueue(
        label: "Scribe.TextInjector.typing",
        qos: .userInitiated
    )

    private static func typeString(
        _ text: String,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let chunks = utf16Chunks(text)
        typingQueue.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            var allPosted = true

            for (index, chunk) in chunks.enumerated() {
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                } else {
                    allPosted = false
                }
                if index < chunks.count - 1 { usleep(8_000) }
            }

            if let completion {
                Task { @MainActor in completion(allPosted) }
            }
        }
    }

    /// Splits UTF-16 at scalar boundaries. This keeps the two halves of a
    /// surrogate pair on the same synthesized keyboard event.
    static func utf16Chunks(_ text: String, maxUnits: Int = 20) -> [[UInt16]] {
        precondition(maxUnits >= 2)
        let units = Array(text.utf16)
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxUnits, units.count)
            if end < units.count,
               (0xD800 ... 0xDBFF).contains(units[end - 1]),
               (0xDC00 ... 0xDFFF).contains(units[end]) {
                end -= 1
            }
            chunks.append(Array(units[start ..< end]))
            start = end
        }
        return chunks
    }
}
