import Foundation

public enum TreeFormatter {
    public static func sanitizeSingleLine(_ text: String, maxLength: Int = 120) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard collapsed.count > maxLength else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: max(0, maxLength - 3))
        return String(collapsed[..<idx]) + "..."
    }

    public static func quote(_ text: String, maxLength: Int = 100) -> String {
        let clean = sanitizeSingleLine(text, maxLength: maxLength)
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(clean)\""
    }

    public static func formatElementLine(_ el: UIElementNode) -> String {
        var parts: [String] = [el.id, el.role]

        let labelText = sanitizeSingleLine(el.label, maxLength: 90)
        parts.append(labelText.isEmpty ? "\"\"" : quote(labelText, maxLength: 90))

        if let val = el.value, !val.isEmpty {
            let cleanVal = sanitizeSingleLine(val, maxLength: 100)
            if cleanVal != labelText {
                parts.append("val=\(quote(cleanVal, maxLength: 100))")
            }
        }

        parts.append("(\(el.bounds.compactString))")

        var flags: [String] = []
        if el.source == .ocr { flags.append("ocr") }
        if !el.enabled { flags.append("disabled") }
        if el.focused { flags.append("focused") }
        if let selected = el.selected, selected { flags.append("selected") }
        if let checked = el.checked { flags.append("checked=\(checked)") }
        if !el.actions.isEmpty {
            flags.append(el.actions.joined(separator: ","))
        }

        if !flags.isEmpty {
            parts.append(flags.joined(separator: " "))
        }

        return parts.joined(separator: " | ")
    }

    public static func formatSnapshot(_ snapshot: ScreenSnapshot, maxElements: Int = 100) -> String {
        var lines: [String] = []

        if let bundle = snapshot.frontBundleId {
            lines.append("APP: \(snapshot.frontApp) (\(bundle), pid=\(snapshot.frontPid))")
        } else {
            lines.append("APP: \(snapshot.frontApp) (pid=\(snapshot.frontPid))")
        }

        if let win = snapshot.focusedWindow {
            let title = win.title.isEmpty ? "(untitled)" : quote(win.title, maxLength: 80)
            lines.append("WINDOW: \(title) (\(win.id), \(win.bounds.compactString))")
        } else {
            lines.append("WINDOW: (none)")
        }

        let otherWindows = snapshot.windows
            .filter { $0.id != snapshot.focusedWindow?.id }
            .prefix(8)
        if !otherWindows.isEmpty {
            let summary = otherWindows.map { win in
                let title = win.title.isEmpty ? "" : ": \(sanitizeSingleLine(win.title, maxLength: 35))"
                return "\(win.id)=\(win.appName)\(title)"
            }.joined(separator: ", ")
            lines.append("OTHER_WINDOWS: \(summary)")
        }

        for note in snapshot.notes {
            lines.append("NOTE: \(note)")
        }

        let limit = max(1, maxElements)
        let shown = Array(snapshot.elements.prefix(limit))
        lines.append("ELEMENTS (showing \(shown.count)/\(snapshot.elements.count)):")

        if shown.isEmpty {
            lines.append("(no elements captured)")
        } else {
            for el in shown {
                lines.append(formatElementLine(el))
            }
        }

        return lines.joined(separator: "\n")
    }

    public static func formatWindows(_ windows: [WindowInfo]) -> String {
        if windows.isEmpty {
            return "No visible application windows."
        }
        return windows.map { win in
            let title = win.title.isEmpty ? "\"\"" : quote(win.title, maxLength: 80)
            let focus = win.isFocused ? " [focused]" : ""
            return "\(win.id) | \(win.appName) | \(title) | (\(win.bounds.compactString)) | pid=\(win.pid)\(focus)"
        }.joined(separator: "\n")
    }

    public static func formatMenu(_ items: [MenuItemInfo], maxItems: Int = 150) -> String {
        if items.isEmpty {
            return "(no menu items found)"
        }
        let shown = Array(items.prefix(max(1, maxItems)))
        var lines = ["MENU ITEMS (showing \(shown.count)/\(items.count)):"]
        for item in shown {
            var parts = [item.id, quote(item.path, maxLength: 100)]
            if let shortcut = item.shortcut, !shortcut.isEmpty {
                parts.append(shortcut)
            }
            if !item.enabled {
                parts.append("disabled")
            }
            lines.append(parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    private struct ElementSignature: Hashable {
        let role: String
        let label: String
        let source: ElementSource
    }

    public static func computeDiff(previous: ScreenSnapshot?, current: ScreenSnapshot) -> ScreenDiff? {
        guard let previous else { return nil }

        let prevTitle = previous.focusedWindow?.title ?? ""
        let currTitle = current.focusedWindow?.title ?? ""
        let appChanged = previous.frontPid != current.frontPid || previous.frontApp != current.frontApp
        let windowChanged = appChanged || prevTitle != currTitle

        var prevCounts: [ElementSignature: Int] = [:]
        var prevValues: [ElementSignature: [String]] = [:]
        for el in previous.elements {
            let sig = ElementSignature(role: el.role, label: el.label, source: el.source)
            prevCounts[sig, default: 0] += 1
            if let v = el.value {
                prevValues[sig, default: []].append(v)
            }
        }

        var currCounts: [ElementSignature: Int] = [:]
        var added: [UIElementNode] = []
        var changedValues: [String] = []

        var remainingPrev = prevCounts
        for el in current.elements {
            let sig = ElementSignature(role: el.role, label: el.label, source: el.source)
            currCounts[sig, default: 0] += 1
            if let count = remainingPrev[sig], count > 0 {
                remainingPrev[sig] = count - 1
                if let prevValList = prevValues[sig],
                   let newVal = el.value,
                   !prevValList.contains(newVal) {
                    changedValues.append("\(el.id) (\(el.role) \(quote(el.label, maxLength: 40))): val=\(quote(newVal, maxLength: 60))")
                }
            } else {
                added.append(el)
            }
        }

        let removedCount = remainingPrev.values.reduce(0, +)

        return ScreenDiff(
            appChanged: appChanged,
            windowChanged: windowChanged,
            previousApp: previous.frontApp,
            currentApp: current.frontApp,
            previousWindowTitle: prevTitle,
            currentWindowTitle: currTitle,
            addedElements: added,
            removedCount: removedCount,
            changedValues: changedValues
        )
    }

    public static func formatDiff(_ diff: ScreenDiff) -> String {
        var lines: [String] = []
        if diff.appChanged {
            lines.append("DIFF: App switched \(diff.previousApp) -> \(diff.currentApp)")
        } else if diff.windowChanged {
            lines.append("DIFF: Window changed \(quote(diff.previousWindowTitle, maxLength: 50)) -> \(quote(diff.currentWindowTitle, maxLength: 50))")
        } else if diff.addedElements.isEmpty && diff.removedCount == 0 && diff.changedValues.isEmpty {
            lines.append("DIFF: No visible UI tree changes detected.")
            return lines.joined(separator: "\n")
        } else {
            lines.append("DIFF: +\(diff.addedElements.count) added, -\(diff.removedCount) removed, \(diff.changedValues.count) value changes")
        }

        if !diff.addedElements.isEmpty {
            for el in diff.addedElements.prefix(12) {
                lines.append("  + \(formatElementLine(el))")
            }
            if diff.addedElements.count > 12 {
                lines.append("  + ... and \(diff.addedElements.count - 12) more added elements")
            }
        }
        for change in diff.changedValues.prefix(8) {
            lines.append("  ~ \(change)")
        }
        return lines.joined(separator: "\n")
    }
}
