/// The panes of the Settings window (⌘,), in the order they appear in the tab bar.
///
/// The tab list, its titles, and the tab the window opens on are the only decidable parts of
/// the tabbed layout, so they live here (and are unit-tested) rather than inside the view.
enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case providers
    case notifications

    /// The tab selected when the Settings window opens.
    static let initial = SettingsTab.general

    var title: String {
        switch self {
        case .general:
            return "General"
        case .providers:
            return "Providers"
        case .notifications:
            return "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .providers:
            return "square.stack.3d.up"
        case .notifications:
            return "bell"
        }
    }
}
