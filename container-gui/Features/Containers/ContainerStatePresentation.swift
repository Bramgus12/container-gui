import SwiftUI

/// The single vocabulary for showing a container's state. Every dot, chip and
/// row label resolves through here, so a state reads the same — and translates
/// the same — everywhere it appears.
extension ContainerState {
    var designState: DSState {
        switch self {
        case .running: .running
        case .paused: .attention
        case .created, .stopped, .unknown: .idle
        }
    }

    var localizedTitle: LocalizedStringResource {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .created: "Created"
        case .stopped: "Stopped"
        case .unknown(let value): "\(value.capitalized)"
        }
    }

    /// For the APIs that take a plain `String` — inspector rows, overview cards.
    var localizedTitleString: String {
        String(localized: localizedTitle)
    }
}
