import AppKit
import SwiftUI
import UsageCore

enum ProviderIconAsset {
    private static let resourceBundleName = "AIUsageBar_AIUsageBarApp.bundle"

    static func image(for provider: ProviderID, pointSize: CGFloat? = nil) -> NSImage? {
        guard
            let bundle = resourceBundle(),
            let url = bundle.url(
                forResource: resourceBaseName(for: provider),
                withExtension: "svg"
            ),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        if let pointSize {
            image.size = NSSize(width: pointSize, height: pointSize)
        }
        image.isTemplate = true
        return image
    }

    private static func resourceBundle() -> Bundle? {
        candidateResourceBundleURLs()
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap(Bundle.init(url:))
    }

    private static func candidateResourceBundleURLs() -> [URL] {
        let baseURLs = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ].compactMap(\.self)

        return baseURLs.flatMap { baseURL in
            ancestors(of: baseURL).map { ancestor in
                ancestor.appendingPathComponent(resourceBundleName, isDirectory: true)
            }
        }
    }

    private static func ancestors(of url: URL) -> [URL] {
        var ancestors: [URL] = []
        var current = url
        for _ in 0..<6 {
            ancestors.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                break
            }
            current = parent
        }
        return ancestors
    }

    private static func resourceBaseName(for provider: ProviderID) -> String {
        switch provider {
        case .claude:
            return "ProviderIcon-claude"
        case .codex:
            return "ProviderIcon-codex"
        }
    }
}

struct ProviderIconView: View {
    let provider: ProviderID
    let size: CGFloat

    var body: some View {
        if let image = ProviderIconAsset.image(for: provider, pointSize: size) {
            Image(nsImage: image)
                .renderingMode(.template)
                .frame(width: size, height: size)
                .clipped()
        } else {
            Text(fallbackSymbol)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
        }
    }

    private var fallbackSymbol: String {
        switch provider {
        case .claude:
            return "*"
        case .codex:
            return "#"
        }
    }
}

struct MenuBarLabelView: View {
    let segments: [MenuBarTitleSegment]

    var body: some View {
        if segments.isEmpty {
            Text("AI Usage")
        } else if let image = MenuBarLabelImage.image(for: segments) {
            Image(nsImage: image)
                .renderingMode(.template)
                .frame(width: image.size.width, height: image.size.height)
        } else {
            fallbackLabelText
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var fallbackLabelText: Text {
        segments.enumerated().reduce(Text("")) { partial, element in
            let separator = element.offset == 0 ? Text("") : Text("  ")
            return partial + separator + Text(segmentLabel(element.element))
        }
    }

    private func segmentLabel(_ segment: MenuBarTitleSegment) -> String {
        let prefix = segment.isStale ? "~" : ""
        return "\(prefix)\(segment.value)"
    }
}

enum MenuBarLabelImage {
    private static let iconSize: CGFloat = 13
    private static let iconTextSpacing: CGFloat = 3
    private static let segmentSpacing: CGFloat = 10
    private static let height: CGFloat = 18

    @MainActor
    static func image(for segments: [MenuBarTitleSegment]) -> NSImage? {
        guard !segments.isEmpty else {
            return nil
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let measuredSegments = segments.map { segment in
            let text = label(for: segment)
            return (segment, text, (text as NSString).size(withAttributes: attributes))
        }
        let width = measuredSegments.enumerated().reduce(CGFloat(0)) { partial, element in
            let separator = element.offset == 0 ? CGFloat(0) : segmentSpacing
            return partial + separator + iconSize + iconTextSpacing + ceil(element.element.2.width)
        }

        let image = NSImage(size: NSSize(width: ceil(width), height: height))
        image.lockFocus()
        defer {
            image.unlockFocus()
        }

        var x: CGFloat = 0
        for (index, measuredSegment) in measuredSegments.enumerated() {
            if index > 0 {
                x += segmentSpacing
            }

            let iconRect = NSRect(
                x: x,
                y: (height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            ProviderIconAsset.image(for: measuredSegment.0.provider, pointSize: iconSize)?
                .draw(in: iconRect)
            x += iconSize + iconTextSpacing

            let textY = (height - measuredSegment.2.height) / 2
            (measuredSegment.1 as NSString).draw(
                at: NSPoint(x: x, y: textY),
                withAttributes: attributes
            )
            x += ceil(measuredSegment.2.width)
        }

        image.isTemplate = true
        return image
    }

    private static func label(for segment: MenuBarTitleSegment) -> String {
        let prefix = segment.isStale ? "~" : ""
        return "\(prefix)\(segment.value)"
    }
}
