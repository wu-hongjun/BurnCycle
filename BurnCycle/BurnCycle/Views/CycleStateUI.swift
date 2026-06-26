import SwiftUI

extension CycleState {
    /// Status color shared by views that color a cycle state independently of
    /// plug status (e.g. the menu-bar popover). Charging green, draining orange,
    /// testing blue, idle secondary.
    var color: Color {
        switch self {
        case .charging: return .green
        case .draining: return .orange
        case .testing: return .blue
        case .idle: return .secondary
        }
    }
}
