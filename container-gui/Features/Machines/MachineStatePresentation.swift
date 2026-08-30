import SwiftUI

/// The single vocabulary for showing a machine's state, matching the way
/// `ContainerState` is presented so a dot or chip reads the same on either
/// screen.
extension MachineState {
    var designState: DSState {
        switch self {
        case .running: .running
        case .stopped, .unknown: .idle
        }
    }

    var localizedTitle: LocalizedStringResource {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .unknown(let value): "\(value.capitalized)"
        }
    }

    /// For the APIs that take a plain `String` — inspector rows, accessibility
    /// labels.
    var localizedTitleString: String {
        String(localized: localizedTitle)
    }
}
