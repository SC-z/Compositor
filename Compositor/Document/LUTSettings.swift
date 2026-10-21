import CoreImage
import simd

nonisolated enum LUTInterpolation: String, Codable, CaseIterable, Sendable {
    case trilinear = "Trilinear"
    case tetrahedral = "Tetrahedral"
}

nonisolated enum LUTColorSpace: String, Codable, CaseIterable, Sendable {
    case sRGB = "sRGB"
    case linearSRGB = "Linear sRGB"
    case gamma22 = "Rec.709 / Gamma 2.2"
    case gamma24 = "Rec.709 / Gamma 2.4"
    case rec709 = "Rec.709 / BT.709 curve"
    case appleLog = "Apple Log / Rec.2020"
    case appleLog2 = "Apple Log 2 / Apple Wide Gamut"
    case fLog2 = "F-Log2 / F-Gamut"
    case vLog = "V-Log / V-Gamut"

    var curve: Float { Float(Self.allCases.firstIndex(of: self)!) }

    // All supported primaries use D65. See docs/lut-color-management.md for the definitions.
    var toSRGB: simd_double3x3 {
        func xyz(_ x: Double, _ y: Double) -> SIMD3<Double> { SIMD3(x / y, 1, (1 - x - y) / y) }
        func matrix(_ r: SIMD3<Double>, _ g: SIMD3<Double>, _ b: SIMD3<Double>) -> simd_double3x3 {
            let m = simd_double3x3(columns: (r, g, b))
            let s = m.inverse * xyz(0.3127, 0.3290)
            return simd_double3x3(columns: (r * s.x, g * s.y, b * s.z))
        }
        let srgb = matrix(xyz(0.64, 0.33), xyz(0.30, 0.60), xyz(0.15, 0.06))
        let source: simd_double3x3
        switch self {
        case .appleLog, .fLog2: source = matrix(xyz(0.708, 0.292), xyz(0.170, 0.797), xyz(0.131, 0.046))
        case .appleLog2: source = matrix(xyz(0.725, 0.301), xyz(0.221, 0.814), xyz(0.068, -0.076))
        case .vLog: source = matrix(xyz(0.730, 0.280), xyz(0.165, 0.840), xyz(0.100, -0.030))
        default: return matrix_identity_double3x3
        }
        return srgb.inverse * source
    }
}

nonisolated struct LUTSettings: Codable, Equatable, Sendable {
    var interpolation: LUTInterpolation = .trilinear
    var inputSpace: LUTColorSpace = .sRGB
    var outputSpace: LUTColorSpace = .sRGB
    var inputAlreadyEncoded = false
    var dither: Bool?
    var photocraft: Bool?
    static var standard: LUTSettings { LUTSettings(dither: false, photocraft: true) }
    var hasLegacyColorConversion: Bool { inputSpace != .sRGB || outputSpace != .sRGB || inputAlreadyEncoded }
}
