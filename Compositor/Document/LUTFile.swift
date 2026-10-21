import Foundation

// Ported from PhotoCraft's cms/lutfile.rs; see Resources/PhotoCraft-LICENSE.txt.
nonisolated enum LUTFile {
    static let extensions = ["cube", "3dl", "look"]
    static let maximumSize = 129

    static func make(title: String, size: Int, rgb: [Float], low: [Float] = [0,0,0], high: [Float] = [1,1,1]) throws -> ColorLookup {
        guard (2...maximumSize).contains(size), rgb.count == size * size * size * 3 else { throw ColorLookupError.invalid }
        var rgba = [Float](); rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: rgb.count, by: 3) { rgba.append(contentsOf: [rgb[i], rgb[i+1], rgb[i+2], 1]) }
        let result = ColorLookup(title: title, dimension: size, domainMin: low, domainMax: high, cube: rgba.withUnsafeBytes { Data($0) })
        guard result.isValid else { throw ColorLookupError.invalid }
        return result
    }

    static func generated(title: String, size: Int = 33, transform: (SIMD3<Float>) -> SIMD3<Float>) throws -> ColorLookup {
        guard (2...maximumSize).contains(size) else { throw ColorLookupError.unsupported }
        var rgb = [Float](); rgb.reserveCapacity(size * size * size * 3)
        let m = Float(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let v = transform(SIMD3(Float(r)/m, Float(g)/m, Float(b)/m))
            rgb.append(contentsOf: (0..<3).map { min(1, max(0, v[$0])) })
        } } }
        return try make(title: title, size: size, rgb: rgb)
    }

    static func parse(_ data: Data, filename: String) throws -> ColorLookup {
        guard data.count <= ColorLookup.maximumFileBytes else { throw ColorLookupError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ColorLookupError.invalid }
        let ext = (filename as NSString).pathExtension.lowercased()
        let result: ColorLookup
        if ext == "3dl" { result = try threeDL(text) }
        else if ext == "look" || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { result = try look(text) }
        else { result = try cube(text) }
        guard result.domainMin == [0,0,0], result.domainMax == [1,1,1] else { throw ColorLookupError.customDomain }
        return result
    }

    private static func lines(_ text: String) -> [String] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
            .components(separatedBy: .newlines).map { String($0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces) }
    }

    private static func cube(_ text: String) throws -> ColorLookup {
        var title = "", size = 0, size1 = 0, low: [Float] = [0,0,0], high: [Float] = [1,1,1], rgb = [Float]()
        for line in lines(text) where !line.isEmpty {
            try Task.checkCancellation()
            let parts = line.split(whereSeparator: \.isWhitespace)
            let key = String(parts[0]), rest = parts.dropFirst()
            switch key {
            case "TITLE": title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            case "LUT_3D_SIZE", "LUT_1D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), n >= 2, n <= (key == "LUT_3D_SIZE" ? maximumSize : 1_048_576) else { throw ColorLookupError.unsupported }
                if key == "LUT_3D_SIZE" { size = n } else { size1 = n }
            case "DOMAIN_MIN", "DOMAIN_MAX", "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                let values = rest.compactMap { Float($0) }
                guard values.count == rest.count, values.allSatisfy(\.isFinite) else { throw ColorLookupError.invalid }
                if key.hasSuffix("INPUT_RANGE") {
                    guard values.count == 2 else { throw ColorLookupError.invalid }
                    low = Array(repeating: values[0], count: 3); high = Array(repeating: values[1], count: 3)
                } else {
                    guard values.count == 3 else { throw ColorLookupError.invalid }
                    if key == "DOMAIN_MIN" { low = values } else { high = values }
                }
            default:
                if let first = key.first, "0123456789-+.".contains(first) {
                    let values = parts.compactMap { Float($0) }
                    guard values.count == 3, parts.count == 3, values.allSatisfy(\.isFinite), rgb.count < maximumSize * maximumSize * maximumSize * 3 else { throw ColorLookupError.invalid }
                    rgb.append(contentsOf: values)
                }
            }
        }
        guard (0..<3).allSatisfy({ high[$0] > low[$0] && (high[$0] - low[$0]).isFinite }) else { throw ColorLookupError.invalid }
        if size > 0 { return try make(title: title, size: size, rgb: rgb, low: low, high: high) }
        guard size1 >= 2, rgb.count == size1 * 3 else { throw ColorLookupError.invalid }
        return try generated(title: title) { c in
            var out = SIMD3<Float>.zero
            for k in 0..<3 {
                let t = (c[k] - low[k]) / (high[k] - low[k])
                let x = (t.isFinite ? min(1, max(0, t)) : 0) * Float(size1 - 1)
                let i = min(Int(floor(x)), size1 - 2), f = x - Float(i)
                out[k] = rgb[i * 3 + k] * (1-f) + rgb[(i+1) * 3 + k] * f
            }
            return out
        }
    }

    private static func threeDL(_ text: String) throws -> ColorLookup {
        var rows = [[Double]]()
        for line in lines(text) where !line.isEmpty {
            try Task.checkCancellation()
            if line.hasPrefix("3DMESH") || line.first?.isLetter == true { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            let values = parts.compactMap { Double($0) }
            guard values.count == parts.count, values.allSatisfy(\.isFinite) else { throw ColorLookupError.invalid }
            if values.count == 3 { rows.append(values) }
            guard rows.count <= maximumSize * maximumSize * maximumSize else { throw ColorLookupError.tooLarge }
        }
        let n = Int(pow(Double(rows.count), 1.0 / 3.0).rounded())
        guard (2...maximumSize).contains(n), n*n*n == rows.count else { throw ColorLookupError.invalid }
        let maxValue = rows.flatMap { $0 }.max() ?? 0
        let scale = maxValue <= 1 ? 1 : ([1023.0,4095,16383,65535].first { maxValue <= $0 } ?? maxValue)
        var rgb = [Float](repeating: 0, count: rows.count * 3)
        for (i,row) in rows.enumerated() {
            let r = i / (n*n), g = (i/n) % n, b = i % n, at = ((b*n+g)*n+r)*3
            for k in 0..<3 { rgb[at+k] = Float(row[k] / scale) }
        }
        return try make(title: "", size: n, rgb: rgb)
    }

    private static func look(_ text: String) throws -> ColorLookup {
        func tag(_ name: String) -> String? {
            guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
            return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \r\n\t\""))
        }
        guard let value = tag("size"), let n = Int(value), (2...maximumSize).contains(n), let hex = tag("data") else { throw ColorLookupError.invalid }
        let digits = hex.utf8.compactMap { c -> UInt8? in
            if (48...57).contains(c) { return c-48 }; if (65...70).contains(c) { return c-55 }; if (97...102).contains(c) { return c-87 }; return nil
        }
        guard digits.count % 8 == 0, [n*n*n*3*8,n*n*n*4*8].contains(digits.count) else { throw ColorLookupError.invalid }
        var floats = [Float](); floats.reserveCapacity(digits.count / 8)
        for i in stride(from: 0, to: digits.count, by: 8) {
            var bits: UInt32 = 0
            for b in 0..<4 { bits |= UInt32(digits[i+b*2] * 16 + digits[i+b*2+1]) << (b*8) }
            floats.append(Float(bitPattern: bits))
        }
        if floats.count == n*n*n*4 { floats = stride(from: 0, to: floats.count, by: 4).flatMap { Array(floats[$0..<$0+3]) } }
        return try make(title: tag("title") ?? "", size: n, rgb: floats)
    }

    static let builtins: [(id: String, title: String)] = [
        ("warm", "Warm Filter"), ("cool", "Cool Filter"), ("tealOrange", "Teal & Orange"), ("bleachBypass", "Bleach Bypass"),
        ("fadedFilm", "Faded Film"), ("dayForNight", "Day for Night"), ("monoContrast", "Mono High Contrast"), ("crossProcess", "Cross Process")
    ]

    static func builtin(_ id: String) throws -> ColorLookup {
        guard let title = builtins.first(where: { $0.id == id })?.title else { throw ColorLookupError.invalid }
        func smooth(_ x: Float) -> Float { let x = min(1,max(0,x)); return x*x*(3-2*x) }
        return try generated(title: title) { c in
            let l = c.x * 0.299 + c.y * 0.587 + c.z * 0.114
            switch id {
            case "warm": return c * SIMD3(0.92,0.97,0.85) + SIMD3(0.08,0.02,0)
            case "cool": return c * SIMD3(0.86,0.97,0.9) + SIMD3(0,0.01,0.1)
            case "tealOrange":
                let t = smooth(l), tint = SIMD3<Float>(0,0.5,0.55) * (1-t) + SIMD3<Float>(1,0.62,0.3) * t
                return SIMD3((0..<3).map { c[$0]*0.75 + min(1,tint[$0]*l*1.1)*0.25 + (smooth(c[$0])-c[$0])*0.3 })
            case "bleachBypass": return (c*0.45 + SIMD3(repeating: l)*0.55)*0.5 + SIMD3(repeating: smooth(l))*0.5
            case "fadedFilm": return (SIMD3(repeating: 0.08) + (c*0.8 + SIMD3(repeating: l)*0.2)*0.84) * SIMD3(1,0.96,0.88) + SIMD3(repeating: 0.02)
            case "dayForNight": return SIMD3(l*0.35,l*0.45+c.y*0.05,l*0.65+c.z*0.15)
            case "monoContrast": return SIMD3(repeating: smooth(smooth(l)))
            default: return SIMD3(smooth(c.x)*1.05,c.y*1.1-0.03,c.z*0.7+0.15)
            }
        }
    }
}
