import SwiftUI

/// Selects the `State` property wrapper without resolving to the same-named
/// macro introduced in the macOS 27 SDK. Command Line Tools ship that SDK
/// without its SwiftUIMacros plugin, so bare `@State` fails to compile there.
/// An alias preserves the wrapper's storage and bindings on macOS 14+.
typealias ViewState<Value> = SwiftUI.State<Value>
