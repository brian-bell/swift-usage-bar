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

    static var rowAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    @MainActor
    static func image(for segments: [MenuBarTitleSegment]) -> NSImage? {
        guard !segments.isEmpty else {
            return nil
        }

        let attributes = rowAttributes
        let rows = segments.map { segment -> (text: NSString, size: NSSize) in
            let text = rowLabel(for: segment) as NSString
            return (text, text.size(withAttributes: attributes))
        }
        let width = ceil(rows.map(\.size.width).max() ?? 0)
        let height = rowHeight * CGFloat(rows.count)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer {
            image.unlockFocus()
        }

        for (index, row) in rows.enumerated() {
            let rowMinY = height - rowHeight * CGFloat(index + 1)
            let textY = rowMinY + (rowHeight - row.size.height) / 2
            row.text.draw(at: NSPoint(x: 0, y: textY), withAttributes: attributes)
        }

        image.isTemplate = true
        return image
    }

    static func rowLabel(for segment: MenuBarTitleSegment) -> String {
        let prefix = segment.isStale ? "~" : ""
        return "\(abbreviation(for: segment.provider)) \(prefix)\(segment.value)"
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
