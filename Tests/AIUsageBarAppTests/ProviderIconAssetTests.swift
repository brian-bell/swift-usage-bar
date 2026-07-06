import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
@MainActor
func providerIconAssetsLoadForAllProviders() throws {
    for provider in ProviderID.allCases {
        let image = try #require(ProviderIconAsset.image(for: provider))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}

@Test
@MainActor
func providerIconAssetsCanBeLoadedAtMenuBarPointSize() throws {
    for provider in ProviderID.allCases {
        let image = try #require(ProviderIconAsset.image(for: provider, pointSize: 13))
        #expect(image.size.width == 13)
        #expect(image.size.height == 13)
    }
}
