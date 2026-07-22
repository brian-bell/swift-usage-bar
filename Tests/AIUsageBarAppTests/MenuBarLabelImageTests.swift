import AppKit
import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
func rowLabelPrefixesProviderAbbreviation() {
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false)
        ) == "Cl 62/81"
    )
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .codex, value: "90", isStale: false)
        ) == "Cx 90"
    )
}

@Test
func rowLabelMarksStaleValuesWithTilde() {
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: true)
        ) == "Cl ~62/81"
    )
}

@Test
func rowLabelRendersMissingDataPlaceholder() {
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .codex, value: "--", isStale: false)
        ) == "Cx --"
    )
}

@Test
@MainActor
func menuBarLabelImageStacksTwoProvidersVertically() throws {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]
    let image = try #require(MenuBarLabelImage.image(for: segments))

    #expect(image.isTemplate)
    #expect(image.size.height == MenuBarLabelImage.rowHeight * 2)
    #expect(image.size.height <= 22)
    #expect(image.size.width == expectedWidth(for: segments))
}

@Test
@MainActor
func menuBarLabelImageSizesStaleAndMissingRowsFromTheirLabels() throws {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: true),
        MenuBarTitleSegment(provider: .codex, value: "--", isStale: false),
    ]
    let image = try #require(MenuBarLabelImage.image(for: segments))

    #expect(image.isTemplate)
    #expect(image.size.height == MenuBarLabelImage.rowHeight * 2)
    #expect(image.size.width == expectedWidth(for: segments))
}

@Test
@MainActor
func menuBarLabelImageRendersSingleProviderAtReadableMenuBarHeight() throws {
    let segments = [
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]
    let image = try #require(MenuBarLabelImage.image(for: segments))

    #expect(image.isTemplate)
    #expect(image.size.height == 18)
}

@Test(arguments: ProviderID.allCases)
@MainActor
func menuBarLabelImageUsesReadableFontForSingleProvider(provider: ProviderID) throws {
    let value = provider == .claude ? "62/81" : "90"
    let segment = MenuBarTitleSegment(provider: provider, value: value, isStale: false)
    let image = try #require(MenuBarLabelImage.image(for: [segment]))
    let readableAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let expectedWidth = ceil(
        (MenuBarLabelImage.rowLabel(for: segment) as NSString)
            .size(withAttributes: readableAttributes)
            .width
    )

    #expect(image.size.width == expectedWidth)
}

@Test
@MainActor
func menuBarLabelImageIsNilWhenAllProvidersAreHidden() {
    #expect(MenuBarLabelImage.image(for: []) == nil)
    #expect(MenuBarLabelImage.layout(for: []) == nil)
}

@Test
func menuBarLabelLayoutPlacesFirstSegmentInTopRow() throws {
    let layout = try #require(MenuBarLabelImage.layout(for: [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]))

    let rows = layout.rows
    #expect(rows.map(\.text) == ["Cl 62/81", "Cx 90"])
    // Non-flipped image coordinates: the first segment's row sits above the second's.
    #expect(rows[0].textOrigin.y == rows[1].textOrigin.y + MenuBarLabelImage.rowHeight)
    #expect(rows[1].textOrigin.y >= 0)
    #expect(layout.size.height == MenuBarLabelImage.rowHeight * 2)
}

@Test
func menuBarLabelLayoutPartitionsThreeProvidersAcrossTwoRows() throws {
    let layout = try #require(MenuBarLabelImage.layout(for: [
        MenuBarTitleSegment(provider: .claude, value: "100/100", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "100", isStale: true),
        MenuBarTitleSegment(provider: .openCodeGo, value: "100/--/100", isStale: false),
    ]))

    #expect(layout.rows.map(\.text) == ["Cl 100/100  Cx ~100", "Go 100/--/100"])
    #expect(layout.size.height == 22)
}

@MainActor
private func expectedWidth(for segments: [MenuBarTitleSegment]) -> CGFloat {
    let widest = segments
        .map { segment in
            (MenuBarLabelImage.rowLabel(for: segment) as NSString)
                .size(withAttributes: MenuBarLabelImage.rowAttributes)
                .width
        }
        .max() ?? 0
    return ceil(widest)
}
