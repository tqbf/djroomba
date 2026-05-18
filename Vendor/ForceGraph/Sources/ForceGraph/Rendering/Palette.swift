import SwiftUI

/// Default colour source: a stable hash → hue mapping.
///
/// The same label always maps to the same hue. Saturation/brightness ramps are
/// designed independently for light and dark (per the rendering spec — dark is
/// not a simple inversion of light): dark mode rides more vivid fills on a
/// near-black surface, light mode uses slightly darker, less saturated fills on
/// near-white for legible contrast.
public enum Palette {
    /// FNV-1a 64-bit over the UTF-8 bytes of `label`. Deterministic across
    /// runs and platforms (unlike `Hasher`, which is per-process seeded).
    public static func stableHash(_ label: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Hue in degrees `0..<360`, stable for a given label.
    public static func hue(for label: String) -> Double {
        Double(stableHash(label) % 360)
    }

    /// The default fill colour for a label in the given colour scheme.
    public static func fill(for label: String, scheme: ColorScheme) -> Color {
        let hue = hue(for: label) / 360
        switch scheme {
        case .dark:
            return Color(hue: hue, saturation: 0.72, brightness: 0.92)
        default:
            return Color(hue: hue, saturation: 0.62, brightness: 0.74)
        }
    }

    /// Surface (background) colour. Never pure black — near-black #1C1C1E in
    /// dark, near-white in light.
    public static func surface(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(red: 0.110, green: 0.110, blue: 0.118)
        default:
            return Color(red: 0.965, green: 0.965, blue: 0.970)
        }
    }

    /// Pick near-white or near-black label text by the fill's perceived
    /// luminance so labels stay WCAG-AA legible on every generated hue.
    public static func textColor(onFill label: String, scheme: ColorScheme) -> Color {
        let hue = hue(for: label) / 360
        let (sat, bri): (Double, Double) = switch scheme {
        case .dark: (0.72, 0.92)
        default: (0.62, 0.74)
        }
        return luminance(hue: hue, saturation: sat, brightness: bri) > 0.6
            ? Color(red: 0.10, green: 0.10, blue: 0.11)
            : Color(red: 0.97, green: 0.97, blue: 0.98)
    }

    /// Relative luminance of an HSB colour (Rec. 709 weights on the RGB form).
    static func luminance(hue: Double, saturation: Double, brightness: Double) -> Double {
        let (r, g, b) = hsbToRGB(hue: hue, saturation: saturation, brightness: brightness)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func hsbToRGB(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
