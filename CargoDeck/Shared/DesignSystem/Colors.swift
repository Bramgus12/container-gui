import SwiftUI

extension Color {
    static let dsCanvas = Color("Canvas")
    static let dsSurface = Color("Surface")
    static let dsSurfaceRaised = Color("SurfaceRaised")
    static let dsHairline = Color("Hairline")
    static let dsTextPrimary = Color("TextPrimary")
    static let dsTextSecondary = Color("TextSecondary")
    static let dsTextTertiary = Color("TextTertiary")
    // The blue ramp does two jobs, and they invert between appearances.
    //
    // Blue100–200 are *tint surfaces*: pale in light, dark in dark, always just
    // far enough off Surface to read as a tinted row. Their dark values are
    // chosen so the contrast against Surface matches the light pair almost
    // exactly (1.14:1 and 1.41:1 against 1.15:1 and 1.38:1).
    //
    // Blue300–700 are *marks*: dots, bars, rails and text, so they run the
    // other way — they must stay legible against the surface behind them, which
    // means darkening on white and lightening on near-black. The design fixes
    // one point of this sub-ramp by naming #4A9BFF the "lifted" dark accent, so
    // dark Blue400 is that value and the neighbours follow by one step.
    //
    // Never paint a mark in Blue100–200 or a surface in Blue300–700; in one of
    // the two appearances it will be invisible. `DesignSystemColorTests` locks
    // both sub-ramps.
    static let dsBlue100 = Color("Blue100")
    static let dsBlue200 = Color("Blue200")
    static let dsBlue300 = Color("Blue300")
    static let dsBlue400 = Color("Blue400")
    static let dsBlue500 = Color("Blue500")
    static let dsBlue700 = Color("Blue700")
    static let dsStateRunning = Color("StateRunning")
    static let dsStateAttention = Color("StateAttention")
    static let dsStateIdle = Color("StateIdle")
    static let dsStateDestructive = Color("StateDestructive")
}
