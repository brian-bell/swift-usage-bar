import AppKit
import ApplicationServices
import Foundation

/// Immutable snapshot of one accessibility node, captured on the main thread
/// during an `onMain` hop (SwiftUI evaluates view state to answer AX requests
/// and asserts the main queue). Value-type attribute copies only — safe to
/// hand back to the background test body.
struct AXNodeSnapshot: Sendable {
    let identifier: String?
    let label: String?
    let value: String?
    let role: String?

    init(element: AXUIElement) {
        self.identifier = Self.axString(element, kAXIdentifierAttribute as String)
        let description = Self.axString(element, kAXDescriptionAttribute as String)
        let title = Self.axString(element, kAXTitleAttribute as String)
        if let description, !description.isEmpty {
            self.label = description
        } else if let title, !title.isEmpty {
            self.label = title
        } else {
            self.label = nil
        }
        self.value = Self.axString(element, kAXValueAttribute as String)
        self.role = Self.axString(element, kAXRoleAttribute as String)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }
}

/// Queries the same-process accessibility tree of a hosted test window.
///
/// Callable from a background test body: every AX access hops to the main
/// thread via `onMain` (see `UITestHost` for why), and the hops are short
/// synchronous walks — never nested run loops.
///
/// Reads-only by design: synthetic input to SwiftUI controls (AX actions or
/// posted mouse events) nondeterministically kills the SwiftPM test runner's
/// main-queue drain in this bundle, truncating the rest of the run. See
/// `docs/ui-test-harness-slice-1.md`.
struct AXQuery {
    let processIdentifier: pid_t
    /// Exact AX title of the host window; no fallback to other windows.
    let windowTitle: String

    init(windowTitle: String) {
        self.processIdentifier = ProcessInfo.processInfo.processIdentifier
        self.windowTitle = windowTitle
    }

    func exists(_ id: String) -> Bool {
        snapshot(id: id) != nil
    }

    func label(_ id: String) -> String? {
        snapshot(id: id)?.label
    }

    func stringValue(_ id: String) -> String? {
        snapshot(id: id)?.value
    }

    /// AX value of the first node matching `label` (checkboxes expose 0/1).
    func stringValue(label: String) -> String? {
        snapshot(label: label)?.value
    }

    func snapshot(id: String) -> AXNodeSnapshot? {
        allSnapshots().first { $0.identifier == id }
    }

    func snapshot(label: String) -> AXNodeSnapshot? {
        allSnapshots().first { $0.label == label }
    }

    func firstLabel(containing needle: String) -> String? {
        allSnapshots()
            .compactMap { $0.label }
            .first { $0.contains(needle) }
    }

    /// First node whose AX value (visible text for AXStaticText) contains
    /// `needle`.
    func firstValue(containing needle: String) -> String? {
        allSnapshots()
            .compactMap { $0.value }
            .first { $0.contains(needle) }
    }

    func dumpIdentifiers(limit: Int = 120) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for node in allSnapshots() {
            guard lines.count < limit else { break }
            if node.identifier == nil && node.label == nil && node.role == nil {
                continue
            }
            let idPart = node.identifier.map { "id=\($0)" } ?? "id=—"
            let titlePart = node.label.map { " title=\($0)" } ?? ""
            let valuePart = node.value.map { " value=\($0)" } ?? ""
            let rolePart = node.role.map { " role=\($0)" } ?? ""
            let line = "\(idPart)\(titlePart)\(valuePart)\(rolePart)"
            if seen.insert(line).inserted {
                lines.append(line)
            }
        }
        return lines.isEmpty ? "(empty tree)" : lines.joined(separator: "\n")
    }

    private func allSnapshots() -> [AXNodeSnapshot] {
        let pid = processIdentifier
        let title = windowTitle
        return onMain {
            AXTreeCollector.collect(processIdentifier: pid, windowTitle: title)
        }
    }
}

enum AXTreeCollector {
    /// Walks the host window's AX children. **Main thread only.**
    static func collect(
        processIdentifier: pid_t,
        windowTitle: String
    ) -> [AXNodeSnapshot] {
        var result: [AXNodeSnapshot] = []
        var seen = Set<UInt>()
        let appElement = AXUIElementCreateApplication(processIdentifier)
        guard let windows = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return result
        }

        // Only the exact host window: never fall back to other windows, which
        // could belong to a sibling test and produce cross-test false positives.
        guard let window = windows.first(where: {
            (copyAttribute($0, kAXTitleAttribute) as? String) == windowTitle
        }) else {
            return result
        }
        walk(window, into: &result, seen: &seen, depth: 0)
        return result
    }

    private static let maxDepth = 25
    private static let maxNodes = 600

    private static func walk(
        _ element: AXUIElement,
        into result: inout [AXNodeSnapshot],
        seen: inout Set<UInt>,
        depth: Int
    ) {
        guard depth < maxDepth, result.count < maxNodes else { return }
        let token = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
        guard !seen.contains(token) else { return }
        seen.insert(token)

        result.append(AXNodeSnapshot(element: element))
        if let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                walk(child, into: &result, seen: &seen, depth: depth + 1)
                if result.count >= maxNodes { return }
            }
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }
}
