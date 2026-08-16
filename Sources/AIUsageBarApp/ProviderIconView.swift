import AppKit
import SwiftUI
import UsageCore

private final class BundleToken {}

enum ProviderIconAsset {
    private static let resourceBundleName = "AIUsageBar_AIUsageBarApp.bundle"

    /// Whether a provider has a published SVG icon. Providers without an asset
    /// (default-hidden providers like MiniMax until a future slice adds one)
    /// fall back to the `fallbackSymbol` text in `ProviderIconView`.
    static func hasAsset(for provider: ProviderID) -> Bool {
        resourceBaseName(for: provider) != nil
    }

    static func image(for provider: ProviderID, pointSize: CGFloat? = nil) -> NSImage? {
        guard
            let bundle = resourceBundle(),
            let resourceBaseName = resourceBaseName(for: provider),
            let url = bundle.url(
                forResource: resourceBaseName,
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
        // Bundle(for:) resolves to the bundle holding this code — under
        // `swift test` that is the xctest bundle in the build directory,
        // where Bundle.main (the test runner) is nowhere near the resources.
        let baseURLs = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BundleToken.self).bundleURL,
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

    private static func resourceBaseName(for provider: ProviderID) -> String? {
        switch provider {
        case .claude:
            return "ProviderIcon-claude"
        case .codex:
            return "ProviderIcon-codex"
        case .openCodeGo, .openCodeCredits:
            // Credits shares the OpenCode mark; the row title disambiguates.
            return "ProviderIcon-opencode-go"
        case .miniMax, .cursor:
            return nil
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
        case .openCodeGo:
            return "G"
        case .openCodeCredits:
            return "$"
        case .miniMax:
            // Single glyph so it fits the square icon frame at the call sites
            // (`size × size`, no scaling). The menu-bar abbreviation stays `Mx`.
            return "M"
        case .cursor:
            return "C"
        }
    }
}
