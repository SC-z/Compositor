import AppKit
import CoreImage
import Testing
@testable import Compositor

@MainActor struct ColorLookupTests {
    nonisolated static func table(size: Int = 2, header: String = "", swap: Bool = false) -> String {
        var lines = ["TITLE \"Test # LUT\"", "LUT_3D_SIZE \(size)", header]
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let values = swap ? [b, r, g] : [r, g, b]
            lines.append(values.map { String(Double($0) / Double(size - 1)) }.joined(separator: " "))
        } } }
        return lines.joined(separator: "\n")
    }

    @Test func parsesCommentsDomainsAndNonPowerOfTwoTables() throws {
        let text = "\u{feff}# comment\r\n" + Self.table(size: 3, header: "DOMAIN_MIN -1 -2 -3\nDOMAIN_MAX 1 2 3")
        let lookup = try ColorLookup.parse(Data(text.utf8))
        #expect(lookup.title == "Test # LUT" && lookup.dimension == 3 && lookup.isValid)
        #expect(lookup.domainMin == [-1, -2, -3] && lookup.domainMax == [1, 2, 3])
        #expect(lookup.cube.count == 27 * 16)
        let restored = try JSONDecoder().decode(ColorLookup.self, from: JSONEncoder().encode(lookup))
        #expect(restored == lookup)
        let blankTitle = Self.table().replacingOccurrences(of: "Test # LUT", with: "   ")
        #expect(try ColorLookup.parse(Data(blankTitle.utf8)).title.isEmpty)
    }

    @Test func rejectsInvalidAndUnsupportedTables() throws {
        let valid = Self.table()
        let broken = [
            "", "LUT_3D_SIZE 9999999999999", "LUT_3D_SIZE -1", "LUT_3D_SIZE 1", "LUT_3D_SIZE 129",
            valid + "\n0 0 0", valid.split(separator: "\n").dropLast().joined(separator: "\n"),
            valid.replacingOccurrences(of: "0.0 0.0 0.0", with: "nan 0 0"),
            valid.replacingOccurrences(of: "0.0 0.0 0.0", with: "0 typo 0 0"),
            Self.table(header: "DOMAIN_MIN 1 1 1"), Self.table(header: "DOMAIN_MAX inf 1 1"),
            Self.table(header: "LUT_3D_INPUT_RANGE 0 1\nDOMAIN_MIN 0 0 0"),
            Self.table(header: "LUT_3D_SIZE 2"), Self.table(header: "LUT_1D_SIZE 2"),
            Self.table(header: "LUT_3D_INPUT_RANGE 1 0"), "LUT_1D_SIZE 2\n0 0 0\n1 1 1",
        ]
        for text in broken { #expect(throws: ColorLookupError.self) { try ColorLookup.parse(Data(text.utf8)) } }
        #expect(throws: ColorLookupError.self) { try ColorLookup.parse(Data([0xff])) }
    }

    @Test func mapsChannelsAndDomainInterpolatesAndPreservesAlpha() throws {
        let fixtures = AdjustmentLayerTests()
        let source = try fixtures.image(PaletteColor(red: 0.2, green: 0.4, blue: 0.6), alpha: [255, 128, 32, 0]).image
        let lookup = try ColorLookup.parse(Data(Self.table(swap: true).utf8))
        let before = try fixtures.pixels(source), after = try fixtures.pixels(lookup.apply(source, sixteenBit: false))
        for p in stride(from: 0, to: 16, by: 4) {
            #expect(abs(Int(after[p]) - Int(before[p + 2])) <= 1)
            #expect(abs(Int(after[p + 1]) - Int(before[p])) <= 1)
            #expect(abs(Int(after[p + 2]) - Int(before[p + 1])) <= 1)
            #expect(after[p + 3] == before[p + 3])
        }
        let domain = try ColorLookup.parse(Data(Self.table(header: "LUT_3D_INPUT_RANGE 0.2 0.6").utf8))
        let mapped = try fixtures.pixels(domain.apply(source, sixteenBit: false))
        #expect(mapped[0] <= 1 && abs(Int(mapped[1]) - 128) <= 1 && mapped[2] >= 254)
        let clipped = try fixtures.image(PaletteColor(red: 0, green: 1, blue: 0.4)).image
        let clippedPixels = try fixtures.pixels(domain.apply(clipped, sixteenBit: false))
        #expect(clippedPixels[0] == 0 && clippedPixels[1] == 255)
        let deep = try DeepLayer.context(width: 1, height: 1)
        let pixels = try #require(deep.data).assumingMemoryBound(to: UInt16.self)
        pixels[0] = 12345; pixels[1] = 23456; pixels[2] = 34567; pixels[3] = 65535
        let result = try lookup.apply(#require(deep.makeImage()), sixteenBit: true)
        #expect(result.bitsPerComponent == 16)
        let domainResult = try domain.apply(#require(deep.makeImage()), sixteenBit: true)
        let domainOutput = try DeepLayer.canonical(domainResult)
        let domainValues = try #require(domainOutput.data).assumingMemoryBound(to: UInt16.self)
        #expect(domainValues[0] == 0)
        #expect(abs(Int(domainValues[1]) - Int(((Float(23456) / 65535 - 0.2) / 0.4 * 65535).rounded())) <= 2)
        let output = try DeepLayer.canonical(result)
        let values = try #require(output.data).assumingMemoryBound(to: UInt16.self)
        #expect(abs(Int(values[0]) - 34567) <= 2 && abs(Int(values[1]) - 12345) <= 2 && abs(Int(values[2]) - 23456) <= 2, "16-bit output: \(values[0]), \(values[1]), \(values[2])")
    }

    @Test func importsNonDestructivelySupportsMaskOpacityUndoAndReplacement() async throws {
        let fixtures = AdjustmentLayerTests(), session = EditorSession()
        session.createDocument(width: 2, height: 2)
        let original = try fixtures.image(PaletteColor(red: 1, green: 0, blue: 0))
        session.insert(original)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LUT-\(UUID()).cube")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(Self.table(swap: true).utf8).write(to: url)
        await session.importColorLookup(from: url)
        let id = try #require(session.activeLayerID)
        #expect(session.activeLayer?.adjustment?.kind == .colorLookup && session.activeLayer?.asset == nil)
        #expect(Array(try await fixtures.rendered(session).prefix(4)) == [0, 255, 0, 255])
        session.document?.layers[1].opacity = 0.5
        let half = try await fixtures.rendered(session)
        #expect(abs(Int(half[0]) - 128) <= 1 && abs(Int(half[1]) - 128) <= 1)
        session.document?.layers[1].opacity = 1
        session.document?.layers[1].mask = LayerMask.solid(revealing: false)
        #expect(Array(try await fixtures.rendered(session).prefix(4)) == [255, 0, 0, 255])
        session.document?.layers[1].mask = nil
        try Data(Self.table().utf8).write(to: url)
        await session.importColorLookup(from: url, replacing: id)
        #expect(Array(try await fixtures.rendered(session).prefix(4)) == [255, 0, 0, 255])
        #expect(session.history.retainedBytes(current: session.document) == 2 * 2 * 2 * 16)
        session.undo()
        #expect(Array(try await fixtures.rendered(session).prefix(4)) == [0, 255, 0, 255])
        session.undo()
        #expect(session.document?.layers.count == 1)
        session.redo()
        #expect(session.document?.layers.count == 2)
        session.deleteLayerOrMask()
        #expect(session.document?.layers.first?.asset?.image === original.image)
        #expect(Array(try await fixtures.rendered(session).prefix(4)) == [255, 0, 0, 255])
        let before = session.document
        try Data("LUT_3D_SIZE 2\n0 0 0".utf8).write(to: url)
        await session.importColorLookup(from: url)
        #expect(session.document == before && session.importError != nil && !session.isImporting)
    }

    @Test func packageEmbedsLookupAndRejectsMissingCorruptAndLegacyData() async throws {
        let fixtures = AdjustmentLayerTests(), session = EditorSession()
        session.createDocument(width: 2, height: 2)
        session.insert(try fixtures.image(PaletteColor(red: 1, green: 0, blue: 0)))
        let lookup = try ColorLookup.parse(Data(Self.table(size: 33, swap: true).utf8))
        session.addAdjustment(.colorLookup, colorLookup: lookup)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LUT-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.last?.adjustment?.colorLookup == lookup)
        let restored = EditorSession(); restored.installProject(loaded, from: url)
        #expect(try await fixtures.rendered(restored) == fixtures.rendered(session))
        let manifestData = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        #expect(manifestData.count < 10_000)
        let metadata = try JSONDecoder().decode(ProjectManifest.self, from: manifestData)
        #expect(metadata.layers.last?.adjustment?.colorLookup == nil)
        let file = url.appendingPathComponent("lookups").appendingPathComponent(try #require(metadata.layers.last?.colorLookupFile))
        var legacy = snapshot.manifest; legacy.version = 14
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: legacy, images: snapshot.images), to: url)
        }
        #expect(try await ProjectStore.shared.load(from: url).manifest.version == ProjectManifest.current)
        try Data("{}".utf8).write(to: file)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: url) }
        try FileManager.default.removeItem(at: file)
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: url) }
    }
}
