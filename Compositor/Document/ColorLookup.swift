import AppKit
import CoreImage
import UniformTypeIdentifiers

/// A .cube table in red-fastest order. The package embeds it, so it never depends on the imported file.
nonisolated final class ColorLookup: Codable, Equatable, Sendable {
    let title: String
    let dimension: Int
    let domainMin: [Float]
    let domainMax: [Float]
    /// Little-endian Float32 RGBA, with alpha one at every entry.
    let cube: Data
    let texture: CIImage
    static let maximumFileBytes = 128 * 1024 * 1024

    private enum CodingKeys: String, CodingKey { case title, dimension, domainMin, domainMax, cube }

    convenience init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: try values.decode(String.self, forKey: .title), dimension: try values.decode(Int.self, forKey: .dimension),
                  domainMin: try values.decode([Float].self, forKey: .domainMin), domainMax: try values.decode([Float].self, forKey: .domainMax),
                  cube: try values.decode(Data.self, forKey: .cube))
        guard isValid else { throw ColorLookupError.invalid }
    }

    init(title: String, dimension: Int, domainMin: [Float], domainMax: [Float], cube: Data) {
        self.title = title
        self.dimension = dimension
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.cube = cube
        if (2...129).contains(dimension), cube.count == dimension * dimension * dimension * 16 {
            let width = dimension * min(dimension, 16), height = (dimension * dimension * dimension + width - 1) / width
            var padded = cube
            padded.append(Data(count: width * height * 16 - cube.count))
            texture = CIImage(bitmapData: padded, bytesPerRow: width * 16,
                              size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
        } else { texture = .empty() }
    }

    static func == (lhs: ColorLookup, rhs: ColorLookup) -> Bool {
        lhs === rhs || (lhs.title == rhs.title && lhs.dimension == rhs.dimension
            && lhs.domainMin == rhs.domainMin && lhs.domainMax == rhs.domainMax && lhs.cube == rhs.cube)
    }

    var isValid: Bool {
        guard (2...129).contains(dimension), title.utf8.count <= 1024,
              domainMin.count == 3, domainMax.count == 3,
              cube.count == dimension * dimension * dimension * 16 else { return false }
        for channel in 0..<3 {
            let low = domainMin[channel], high = domainMax[channel]
            guard low.isFinite, high.isFinite, high > low,
                  (1 / (high - low)).isFinite, (low / (high - low)).isFinite, (high - low).isFinite else { return false }
        }
        return cube.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                guard value.isFinite, abs(value) <= 65504,
                      offset % 16 != 12 || value == 1 else { return false }
            }
            return true
        }
    }

    static func read(from url: URL, photocraft: Bool = false) throws -> ColorLookup {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= maximumFileBytes else { throw ColorLookupError.tooLarge }
        let data = try Data(contentsOf: url)
        return try photocraft ? LUTFile.parse(data, filename: url.lastPathComponent) : parse(data, name: url.deletingPathExtension().lastPathComponent)
    }

    static func parse(_ data: Data, name: String = "LUT") throws -> Self {
        guard data.count <= maximumFileBytes else { throw ColorLookupError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ColorLookupError.invalid }
        var title = String(name.prefix(200)), dimension: Int?
        var low: [Float] = [0, 0, 0], high: [Float] = [1, 1, 1]
        var headers = Set<String>(), cube = Data()
        for raw in text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("TITLE ") || line.hasPrefix("TITLE\t") {
                guard cube.isEmpty, headers.insert("TITLE").inserted,
                      let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else {
                    throw ColorLookupError.invalid
                }
                title = String(line[line.index(after: first)..<last])
                guard title.utf8.count <= 1024 else { throw ColorLookupError.invalid }
                continue
            }
            let fields = line.split(separator: "#", maxSplits: 1)[0].split(whereSeparator: \.isWhitespace)
            guard let key = fields.first else { continue }
            if key == "LUT_1D_SIZE" || key == "LUT_1D_INPUT_RANGE" { throw ColorLookupError.unsupported }
            if ["LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_3D_INPUT_RANGE"].contains(String(key)) {
                guard cube.isEmpty, headers.insert(String(key)).inserted else { throw ColorLookupError.invalid }
                if key == "LUT_3D_SIZE" {
                    guard fields.count == 2, let size = Int(fields[1]), (2...129).contains(size) else {
                        throw ColorLookupError.unsupported
                    }
                    dimension = size
                    cube.reserveCapacity(size * size * size * 16)
                } else {
                    let values = fields.dropFirst().compactMap { Float($0) }
                    guard values.count == fields.count - 1, values.allSatisfy(\.isFinite) else { throw ColorLookupError.invalid }
                    if key == "LUT_3D_INPUT_RANGE" {
                        guard values.count == 2, !headers.contains("DOMAIN_MIN"), !headers.contains("DOMAIN_MAX") else {
                            throw ColorLookupError.invalid
                        }
                        low = Array(repeating: values[0], count: 3); high = Array(repeating: values[1], count: 3)
                    } else {
                        guard values.count == 3, !headers.contains("LUT_3D_INPUT_RANGE") else { throw ColorLookupError.invalid }
                        if key == "DOMAIN_MIN" { low = values } else { high = values }
                    }
                }
            } else {
                guard let size = dimension, fields.count == 3, cube.count < size * size * size * 16 else {
                    throw ColorLookupError.invalid
                }
                let values = fields.compactMap { Float($0) }
                guard values.count == 3, values.allSatisfy({ $0.isFinite && abs($0) <= 65504 }) else {
                    throw ColorLookupError.invalid
                }
                for value in values + [1] {
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { cube.append(contentsOf: $0) }
                }
            }
        }
        guard let dimension else { throw ColorLookupError.invalid }
        let result = Self(title: title.trimmingCharacters(in: .whitespacesAndNewlines), dimension: dimension,
                          domainMin: low, domainMax: high, cube: cube)
        guard result.isValid else { throw ColorLookupError.invalid }
        return result
    }

    /// Canvas and export share the same lookup and input-domain mapping, in the document's encoded sRGB space.
    func applying(to image: CIImage, settings: LUTSettings = LUTSettings(), mapping: CGAffineTransform = .identity) -> CIImage? {
        if settings != LUTSettings() || dimension > 128 { return LUTKernel.apply(image, lookup: self, settings: settings, mapping: mapping) }
        let scale = (0..<3).map { CGFloat(1 / (domainMax[$0] - domainMin[$0])) }
        let bias = (0..<3).map { -CGFloat(domainMin[$0]) * scale[$0] }
        let straight = image.unpremultiplyingAlpha().settingAlphaOne(in: image.extent)
        let mapped = straight.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale[2], w: 0),
            "inputBiasVector": CIVector(x: bias[0], y: bias[1], z: bias[2], w: 0),
        ]).applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": cube])
        return mapped.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: image,
        ]).cropped(to: image.extent)
    }

    func apply(_ image: CGImage, sixteenBit: Bool, settings: LUTSettings = LUTSettings(), region: CGRect? = nil, scale: CGFloat = 1, isMask: Bool = false) throws -> CGImage {
        // Core Image's texture interpolation quantizes coordinates even with a Float32 working surface.
        if settings == LUTSettings(), dimension <= 128, sixteenBit, !DeepLayer.isHDR(image) {
            return try DeepLayer.lookup(image, cube: cube, dimension: dimension, domain: (domainMin, domainMax))
        }
        let region = region ?? CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let mapping = CGAffineTransform(a: 1 / scale, b: 0, c: 0, d: -1 / scale, tx: region.minX, ty: region.minY + CGFloat(image.height) / scale)
        guard let result = applying(to: CIImage(cgImage: image), settings: settings, mapping: mapping) else { throw ExportError.render }
        if isMask {
            // PhotoCraft converts the lookup's RGB output to Rec.601 grayscale for masks.
            let gray = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
            let output = result.applyingFilter("CIColorMatrix", parameters: ["inputRVector": gray, "inputGVector": gray, "inputBVector": gray])
            return try PixelAdjust.render(output, width: image.width, height: image.height, isMask: true)
        }
        if sixteenBit { return try DeepLayer.render(result, width: image.width, height: image.height, hdr: DeepLayer.isHDR(image)) }
        return try PixelAdjust.render(result, width: image.width, height: image.height, isMask: false)
    }
}

nonisolated enum ColorLookupError: LocalizedError {
    case invalid, unsupported, tooLarge, customDomain
    var errorDescription: String? {
        switch self {
        case .invalid: localized("The LUT is invalid or incomplete. The document has not been changed.")
        case .unsupported: localized("Choose a .cube, .3dl or .look LUT. 3D grid sizes from 2 to 129 are supported; combined 1D/3D tables are not.")
        case .customDomain: localized("This 3D LUT uses a custom input range. PhotoCraft-compatible presets require a 0–1 range.")
        case .tooLarge: localized("The LUT file exceeds the 128 MiB limit.")
        }
    }
}

extension EditorSession {
    func importColorLookup(from suppliedURL: URL? = nil, replacing id: UUID? = nil) async {
        guard !isImporting, canEditLayers || (id != nil && adjustmentEditingID == id),
              let documentID = document?.id else { return }
        isImporting = true
        defer { isImporting = false }
        guard let url = suppliedURL else {
            isImporting = false
            beginPresetEditing(id)
            return
        }
        do {
            let lookup = try await Task.detached(priority: .userInitiated) { try ColorLookup.read(from: url, photocraft: true) }.value
            guard document?.id == documentID else { return }
            isImporting = false
            if let id {
                guard let index = document?.layers.firstIndex(where: { $0.id == id }),
                      document?.layers[index].adjustment?.kind == .colorLookup else { return }
                beginEdit("Replace LUT")
                let previous = document?.layers[index].adjustment?.resolvedLookupSettings ?? .standard
                var settings = LUTSettings.standard
                settings.interpolation = previous.interpolation; settings.dither = previous.dither ?? false
                document?.layers[index].adjustment?.colorLookup = lookup
                document?.layers[index].adjustment?.lookupSettings = settings
                endEdit()
                brushRevision += 1
            } else { addAdjustment(.colorLookup, colorLookup: lookup, lookupSettings: .standard) }
        } catch { importError = error.localizedDescription }
    }
}
