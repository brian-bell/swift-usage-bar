import AppKit
import SwiftUI
import UsageCore

enum ProviderIconAsset {
    private static let resourceBundleName = "AIUsageBar_AIUsageBarApp.bundle"

    static func image(for provider: ProviderID) -> NSImage? {
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
        if let image = ProviderIconAsset.image(for: provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
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
        } else {
            HStack(spacing: 7) {
                ForEach(segments, id: \.provider) { segment in
                    HStack(spacing: 2) {
                        ProviderIconView(provider: segment.provider, size: 13)
                        Text(segmentLabel(segment))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func segmentLabel(_ segment: MenuBarTitleSegment) -> String {
        let prefix = segment.isStale ? "~" : ""
        return "\(prefix)\(segment.value)"
    }
}
