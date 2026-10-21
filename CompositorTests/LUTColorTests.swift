import AppKit
import CoreImage
import Testing
@testable import Compositor

@MainActor struct LUTColorTests {
    private func render(_ lookup: ColorLookup, _ rgb: [Float], _ settings: LUTSettings) throws -> [Float] {
        let input = CIImage(color: CIColor(red: CGFloat(rgb[0]), green: CGFloat(rgb[1]), blue: CGFloat(rgb[2]), alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(LUTKernel.apply(input, lookup: lookup, settings: settings))
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: image.extent, format: .RGBAf, colorSpace: nil)
        #expect(values[3] == 1)
        return Array(values.prefix(3))
    }

    private func identity() throws -> ColorLookup { try ColorLookup.parse(Data(ColorLookupTests.table().utf8)) }

    @Test func interpolationReadsEveryTetrahedronAndMatchesEndpoints() throws {
        var values = [Float](repeating: 0, count: 32)
        for i in 0..<8 { values[i * 4 + 3] = 1 }
        values[28] = 1; values[29] = 1; values[30] = 1
        let lookup = ColorLookup(title: "corner", dimension: 2, domainMin: [0,0,0], domainMax: [1,1,1], cube: values.withUnsafeBytes { Data($0) })
        let samples: [[Float]] = [[0.2,0.4,0.7], [0.2,0.7,0.4], [0.4,0.2,0.7], [0.4,0.7,0.2], [0.7,0.2,0.4], [0.7,0.4,0.2], [0,0,0], [1,1,1]]
        for rgb in samples {
            let tri = try render(lookup, rgb, LUTSettings())
            let tetra = try render(lookup, rgb, LUTSettings(interpolation: .tetrahedral))
            #expect(abs(tri[0] - rgb.reduce(1, *)) < 0.00002)
            #expect(abs(tetra[0] - rgb.min()!) < 0.00002)
        }
    }

    @Test func logReferencePointsAndColorSpaceRoundTrips() throws {
        let lookup = try identity()
        let gray: Float = 0.46135613 // sRGB encoding of 18% linear reflectance.
        let references: [(LUTColorSpace, Float)] = [(.appleLog, 0.48827246), (.appleLog2, 0.48827246), (.fLog2, 0.39100724), (.vLog, 0.42331145)]
        for (space, expected) in references {
            let encoded = try render(lookup, [gray,gray,gray], LUTSettings(inputSpace: space))
            #expect(encoded.allSatisfy { abs($0 - expected) < 0.00003 })
            let decoded = try render(lookup, [expected,expected,expected], LUTSettings(outputSpace: space, inputAlreadyEncoded: true))
            #expect(decoded.allSatisfy { abs($0 - gray) < 0.00005 })
        }
        for space in LUTColorSpace.allCases {
            let rgb: [Float] = [0.2, 0.35, 0.65]
            let out = try render(lookup, rgb, LUTSettings(interpolation: .tetrahedral, inputSpace: space, outputSpace: space))
            #expect(zip(out, rgb).allSatisfy { abs($0 - $1) < 0.0001 })
        }
        let rgb: [Float] = [0.2, 0.35, 0.65]
        let bypass = try render(lookup, rgb, LUTSettings(inputSpace: .appleLog2, inputAlreadyEncoded: true))
        #expect(zip(bypass, rgb).allSatisfy { abs($0 - $1) < 0.00002 })
        let first = try render(lookup, rgb, LUTSettings(inputSpace: .appleLog))
        let second = try render(lookup, rgb, LUTSettings(inputSpace: .appleLog2))
        #expect(zip(first, second).contains { abs($0 - $1) > 0.001 })
    }

    @Test func settingsPersistCancelAndOldProjectsKeepTheirDefaults() async throws {
        let session = EditorSession()
        session.createDocument(width: 2, height: 2)
        session.insert(try AdjustmentLayerTests().image(PaletteColor(red: 0.2, green: 0.35, blue: 0.65)))
        session.addAdjustment(.colorLookup, colorLookup: try identity())
        let id = try #require(session.activeLayerID), original = session.document
        session.beginPresetEditing(id)
        session.presetEdit?.settings = LUTSettings(interpolation: .tetrahedral, inputSpace: .appleLog2, outputSpace: .gamma24)
        session.applyPresetPreview()
        let settings = try #require(session.presetEdit?.settings)
        #expect(session.document?.layers.last?.adjustment?.lookupSettings == settings)
        session.finishPresetEditing(commit: false)
        #expect(session.document == original)
        session.beginPresetEditing(id)
        session.presetEdit?.settings = settings
        session.finishPresetEditing(commit: true)
        let saved = try #require(session.projectSnapshot())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LUT-settings-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.shared.save(saved, to: root)
        let loaded = try await ProjectStore.shared.load(from: root)
        #expect(loaded.manifest.version == ProjectManifest.current)
        #expect(loaded.manifest.layers.last?.adjustment?.lookupSettings == settings)
        session.undo(); #expect(session.document == original)
        session.redo(); #expect(session.document?.layers.last?.adjustment?.lookupSettings == settings)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LayerAdjustment(kind: .colorLookup, colorLookup: try identity()))) as? [String: Any])
        json.removeValue(forKey: "lookupSettings")
        let old = try JSONDecoder().decode(LayerAdjustment.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.resolvedLookupSettings == LUTSettings())
    }

    @Test func sixteenBitPreservesPrecisionAndAlphaWithNewKernel() throws {
        let context = try DeepLayer.context(width: 3, height: 1)
        let p = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        let expected: [UInt16] = [12345,23456,45678,65535, 10000,15000,20000,32768, 0,0,0,0]
        for i in expected.indices { p[i] = expected[i] }
        let out = try identity().apply(#require(context.makeImage()), sixteenBit: true, settings: LUTSettings(interpolation: .tetrahedral))
        let decoded = try DeepLayer.canonical(out)
        let q = try #require(decoded.data).assumingMemoryBound(to: UInt16.self)
        for i in expected.indices { #expect(abs(Int(q[i]) - Int(expected[i])) <= 2) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_LUT_REFERENCE"] != nil))
    func suppliedFilesMatchIndependentReference() throws {
        struct Case: Decodable { var input: [Float]; var expected: [Float]; var settings: LUTSettings }
        struct File: Decodable { var path: String; var cases: [Case] }
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_LUT_REFERENCE"])
        let files = try JSONDecoder().decode([File].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(files.count == 13)
        for file in files {
            let lookup = try ColorLookup.read(from: URL(fileURLWithPath: file.path))
            #expect(lookup.dimension == 33 && lookup.isValid)
            for item in file.cases {
                let actual = try render(lookup, item.input, item.settings)
                #expect(zip(actual, item.expected).allSatisfy { $0.isFinite && abs($0 - $1) < 0.0002 }, "\(file.path): \(item.settings)")
            }
        }
    }
}
