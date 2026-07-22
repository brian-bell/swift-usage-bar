import AppKit
import SwiftUI
import UsageCore

struct MenuBarLabelView: View {
    let segments: [MenuBarTitleSegment]

    var body: some View {
        if let image = MenuBarLabelImage.image(for: segments) {
            Image(nsImage: image)
                .renderingMode(.template)
                .frame(width: image.size.width, height: image.size.height)
        } else {
            Text("AI Usage")
        }
    }
}

enum MenuBarLabelImage {
    /// Two rows at this height total 22 pt, fitting the 24 pt menu bar slot.
    static let rowHeight: CGFloat = 11
    private static let singleRowHeight: CGFloat = 18

    static var rowAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    private static var singleRowAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    struct Layout {
        struct Row {
            let text: String
            let textOrigin: NSPoint
        }

        let size: NSSize
        let rows: [Row]
    }

    static func layout(for segments: [MenuBarTitleSegment]) -> Layout? {
        guard !segments.isEmpty else {
            return nil
        }

        let attributes = attributes(for: segments.count)
        let measured = segments.map { segment -> (text: String, size: NSSize) in
            let text = rowLabel(for: segment)
            return (text, (text as NSString).size(withAttributes: attributes))
        }
        let width = ceil(measured.map(\.size.width).max() ?? 0)
        let resolvedRowHeight = segments.count == 1 ? singleRowHeight : rowHeight
        let height = resolvedRowHeight * CGFloat(measured.count)
        let rows = measured.enumerated().map { index, row in
            let rowMinY = height - resolvedRowHeight * CGFloat(index + 1)
            return Layout.Row(
                text: row.text,
                textOrigin: NSPoint(x: 0, y: rowMinY + (resolvedRowHeight - row.size.height) / 2)
            )
        }

        return Layout(size: NSSize(width: width, height: height), rows: rows)
    }

    @MainActor
    static func image(for segments: [MenuBarTitleSegment]) -> NSImage? {
        guard let layout = layout(for: segments) else {
            return nil
        }

        let attributes = attributes(for: segments.count)
        let image = NSImage(size: layout.size)
        image.lockFocus()
        defer {
            image.unlockFocus()
        }

        for row in layout.rows {
            (row.text as NSString).draw(at: row.textOrigin, withAttributes: attributes)
        }

        image.isTemplate = true
        return image
    }

    static func rowLabel(for segment: MenuBarTitleSegment) -> String {
        let prefix = segment.isStale ? "~" : ""
        return "\(abbreviation(for: segment.provider)) \(prefix)\(segment.value)"
    }

    private static func attributes(for segmentCount: Int) -> [NSAttributedString.Key: Any] {
        segmentCount == 1 ? singleRowAttributes : rowAttributes
    }

    private static func abbreviation(for provider: ProviderID) -> String {
        switch provider {
        case .claude:
            return "Cl"
        case .codex:
            return "Cx"
        }
    }
}
