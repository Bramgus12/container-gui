import CoreGraphics

enum DSMetrics {
    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing24: CGFloat = 24

    static let controlRadius: CGFloat = 5
    static let inlineRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let tableRowHeight: CGFloat = 28
    static let gutter: CGFloat = 12
    static let hairline: CGFloat = 1

    /// Every configuration sheet opens at the same minimum size, so moving
    /// between modals never resizes the window.
    static let sheetWidth: CGFloat = 760
    static let sheetHeight: CGFloat = 560
}
