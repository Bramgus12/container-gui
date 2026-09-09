import AppKit
import CoreText
import SwiftUI

enum DSFont {
    enum Weight {
        case regular
        case medium
        case semibold

        fileprivate var postScriptName: String {
            switch self {
            case .regular: "GeistMono-Regular"
            case .medium: "GeistMono-Medium"
            case .semibold: "GeistMono-SemiBold"
            }
        }

        fileprivate var systemWeight: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            }
        }
    }

    static func mono(
        size: CGFloat,
        weight: Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        if NSFont(name: weight.postScriptName, size: size) != nil {
            return .custom(weight.postScriptName, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: weight.systemWeight, design: .monospaced)
    }

    static var isGeistMonoAvailable: Bool {
        Weight.allCases.allSatisfy { NSFont(name: $0.postScriptName, size: 12) != nil }
    }

    @discardableResult
    static func registerBundledFontsIfNeeded(bundle: Bundle = .main) -> Bool {
        guard !isGeistMonoAvailable else { return true }
        for weight in Weight.allCases {
            guard let url = bundle.url(
                forResource: weight.postScriptName,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) ?? bundle.url(forResource: weight.postScriptName, withExtension: "ttf") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return isGeistMonoAvailable
    }
}

extension DSFont.Weight: CaseIterable {}

extension Font {
    static let dsDisplay = Font.system(size: 28, weight: .semibold)
    static let dsScreenTitle = Font.system(size: 21, weight: .semibold)
    static let dsCardHeading = Font.system(size: 15, weight: .semibold)
    static let dsBody = Font.system(size: 13, weight: .regular)
    static let dsSectionLabel = Font.system(size: 11, weight: .semibold)
    static let cliMono = DSFont.mono(size: 12.5)
    static let cliMonoDim = DSFont.mono(size: 12.5)
    static let cliMonoTabular = DSFont.mono(size: 12)
}

extension View {
    /// Text fields whose contents are a CLI value — image references, tags,
    /// paths, ports, environment values. The label stays SF; the value is mono,
    /// same as everywhere else the CLI's own strings appear.
    func dsMonoField() -> some View {
        font(.cliMono)
    }
}
