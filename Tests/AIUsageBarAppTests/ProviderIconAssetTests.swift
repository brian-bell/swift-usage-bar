import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
@MainActor
func providerIconAssetsLoadForAllProviders() throws {
    // Pin which providers have an asset before loading — otherwise the loop
    // would skip a regression where a real provider's resourceBaseName
    // returns nil and the suite still passes vacuously.
    #expect(ProviderID.allCases.map(ProviderIconAsset.hasAsset(for:)) == [
        true,  // .claude
        true,  // .codex
        true,  // .openCodeGo
        true,  // .openCodeCredits — shares the OpenCode mark
        false, // .miniMax
    ])
    for provider in ProviderID.allCases where ProviderIconAsset.hasAsset(for: provider) {
        let image = try #require(ProviderIconAsset.image(for: provider))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}

@Test
@MainActor
func providerIconAssetsCanBeLoadedAtMenuBarPointSize() throws {
    for provider in ProviderID.allCases where ProviderIconAsset.hasAsset(for: provider) {
        let image = try #require(ProviderIconAsset.image(for: provider, pointSize: 13))
        #expect(image.size.width == 13)
        #expect(image.size.height == 13)
    }
}

@Test
@MainActor
func providerIconAssetIsAbsentForMiniMax() {
    // Slice 1 ships MiniMax without an SVG; the view falls back to its `Mx`
    // text symbol. Pin the no-asset invariant so adding a stub doesn't
    // silently change which providers render as fallback text.
    #expect(!ProviderIconAsset.hasAsset(for: .miniMax))
    #expect(ProviderIconAsset.image(for: .miniMax) == nil)
}
