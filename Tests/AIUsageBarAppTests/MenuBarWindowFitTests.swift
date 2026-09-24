import AppKit
import Testing

@testable import AIUsageBarApp

@Test
func shrinkingContentKeepsTheTopEdgePinnedUnderTheMenuBar() {
    let current = NSRect(x: 1111, y: 799, width: 320, height: 272)

    let fitted = MenuBarWindowFit.contentRect(fitting: 104, in: current)

    #expect(fitted == NSRect(x: 1111, y: 967, width: 320, height: 104))
    #expect(fitted?.maxY == current.maxY)
}

@Test
func growingContentExtendsDownwardFromThePinnedTopEdge() {
    let current = NSRect(x: 1111, y: 967, width: 320, height: 104)

    let fitted = MenuBarWindowFit.contentRect(fitting: 272, in: current)

    #expect(fitted == NSRect(x: 1111, y: 799, width: 320, height: 272))
}

@Test
func contentThatAlreadyFitsNeedsNoResize() {
    let current = NSRect(x: 1111, y: 799, width: 320, height: 272)

    #expect(MenuBarWindowFit.contentRect(fitting: 272, in: current) == nil)
    #expect(MenuBarWindowFit.contentRect(fitting: 272.3, in: current) == nil)
}
