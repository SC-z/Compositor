import AppKit
import CoreImage
import Testing
@testable import Compositor

@MainActor struct LUTParityTests {
    private func floats(_ lookup: ColorLookup) -> [Float] {
        lookup.cube.withUnsafeBytes { raw in stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)) } }
    }
    private func render(_ lookup: ColorLookup, settings: LUTSettings, size: Int = 4) throws -> [Float] {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let output = try #require(lookup.applying(to: image, settings: settings))
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
        var pixels = [Float](repeating: 0, count: size*size*4)
        context.render(output, toBitmap: &pixels, rowBytes: size*16, bounds: image.extent, format: .RGBAf, colorSpace: nil)
        return pixels
    }

    @Test func fileFormatsMatchPhotoCraftAndRejectMalformedData() throws {
        let identity = try LUTFile.parse(Data(ColorLookupTests.table().utf8), filename: "a.cube")
        let cube = floats(identity)
        let one = try LUTFile.parse(Data("LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0 2\n0 0 0\n1 1 1".utf8), filename: "curve.cube")
        #expect(one.dimension == 33 && floats(one).suffix(4) == [0.5,0.5,0.5,1])
        var three = "3DMESH\n0 1 2 3\n"
        for r in 0...1 { for g in 0...1 { for b in 0...1 { three += "\(r*4095) \(g*4095) \(b*4095)\n" } } }
        #expect(floats(try LUTFile.parse(Data(three.utf8), filename: "a.3dl")) == cube)
        let rawRGB = stride(from: 0, to: cube.count, by: 4).flatMap { Array(cube[$0..<$0+3]) }
        for values in [rawRGB, cube] {
            let hex = values.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
            let xml = "<look><title>Identity</title><size>2</size><data>\"\(hex)\"</data></look>"
            #expect(floats(try LUTFile.parse(Data(xml.utf8), filename: "a.look")) == cube)
        }
        for source in [ColorLookupTests.table(header: "DOMAIN_MIN -1 0 0"), "LUT_3D_SIZE 130", "LUT_1D_SIZE 9999999999999", "LUT_1D_SIZE 2\n0 nan 0\n1 1 1", ColorLookupTests.table(header: "LUT_1D_SIZE 2") + "\n0 0 0\n1 1 1"] {
            #expect(throws: ColorLookupError.self) { try LUTFile.parse(Data(source.utf8), filename: "x.cube") }
        }
        #expect(throws: ColorLookupError.self) { try LUTFile.parse(Data("<size>129</size><data>00</data>".utf8), filename: "x.look") }
        #expect(throws: ColorLookupError.self) { try LUTFile.parse(Data("0 nan 1".utf8), filename: "x.3dl") }
    }

    @Test func allBuiltinsAndMaximumGridRender() throws {
        #expect(LUTFile.builtins.count == 8)
        let gray: [String: [Float]] = ["warm":[0.54,0.505,0.425], "cool":[0.43,0.495,0.55],
            "bleachBypass":[0.5,0.5,0.5], "dayForNight":[0.175,0.25,0.4], "monoContrast":[0.5,0.5,0.5],
            "crossProcess":[0.525,0.52,0.5], "fadedFilm":[0.52,0.5,0.46], "tealOrange":[0.44375,0.452,0.4334375]]
        for entry in LUTFile.builtins {
            let lookup = try LUTFile.builtin(entry.id)
            #expect(lookup.dimension == 33 && lookup.isValid)
            let pixel = try render(lookup, settings: .standard, size: 1)
            let expected = try #require(gray[entry.id])
            #expect(zip(pixel.prefix(3),expected).allSatisfy { abs($0-$1) < 0.00002 }, "\(entry.id): \(pixel)")
        }
        let large = try LUTFile.generated(title: "129", size: 129) { $0 }
        let pixel = try render(large, settings: .standard, size: 1)
        #expect(pixel.allSatisfy(\.isFinite) && abs(pixel[0]-0.5)<0.00002 && pixel[3] == 1)
    }

    @Test func orderedDitherMatchesBayerMatrixAndCanBeDisabled() throws {
        let identity = try LUTFile.generated(title: "Identity", size: 2) { $0 }
        var settings = LUTSettings.standard; settings.dither = true
        let pixels = try render(identity, settings: settings)
        let matrix: [Float] = [0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5]
        // Core Image's bitmap rows run from the top; this kernel's default coordinates run upward.
        for y in 0..<4 { for x in 0..<4 {
            let expected = 0.5 + ((matrix[(3-y)*4+x]+0.5)/16-0.5)/255
            #expect(abs(pixels[(y*4+x)*4]-expected)<0.000002)
            #expect(pixels[(y*4+x)*4+3] == 1)
        } }
        let plain = try render(identity, settings: .standard)
        #expect(stride(from: 0, to: plain.count, by: 4).allSatisfy { abs(plain[$0]-0.5)<0.000002 })
    }

    @Test func noneAndLegacySettingsPersistWithoutSilentConversion() async throws {
        let session = EditorSession(); session.createDocument(width: 2,height: 2)
        session.beginPresetEditing(); session.choosePreset("warm")
        session.presetEdit?.settings.dither = true; session.applyPresetPreview()
        session.choosePreset("cool")
        #expect(session.presetEdit?.settings.dither == true)
        session.choosePreset("none"); #expect(session.finishPresetEditing(commit: true))
        #expect(session.activeLayer?.adjustment?.isValid == true && session.activeLayer?.adjustment?.colorLookup == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LUT-parity-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: root)
        let loaded = try await ProjectStore.shared.load(from: root)
        #expect(loaded.manifest.version == ProjectManifest.current && loaded.manifest.layers.last?.adjustment?.resolvedLookupSettings.dither == true)
        var old = snapshot.manifest; old.version = 16
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(ProjectSnapshot(manifest: old, images: snapshot.images), to: root) }
        let id = try #require(session.activeLayerID)
        session.document?.layers[0].adjustment?.lookupSettings = LUTSettings(inputSpace: .appleLog2, outputSpace: .gamma24)
        session.document?.layers[0].adjustment?.colorLookup = try LUTFile.builtin("warm")
        session.beginPresetEditing(id)
        #expect(session.presetEdit?.settings.inputSpace == .appleLog2)
        session.choosePreset("cool")
        #expect(session.presetEdit?.settings.inputSpace == .sRGB)
        session.finishPresetEditing(commit: false)
        #expect(session.activeLayer?.adjustment?.resolvedLookupSettings.inputSpace == .appleLog2)
    }

    @Test func pixelApplicationPreviewsCancelsAndUndoes() async throws {
        let session = EditorSession(); session.createDocument(width: 2,height: 2)
        session.insert(try AdjustmentLayerTests().image(PaletteColor(red: 0.5,green: 0.5,blue: 0.5), alpha: [255,128,32,0]))
        let original = session.document, count = session.history.undoCount
        session.beginHueSaturation(); session.beginPixelPresets()
        #expect(session.presetEdit == nil && session.hueSaturation != nil)
        session.cancelHueSaturation()
        session.beginPixelPresets()
        #expect(!session.canAdjustColors)
        session.beginHueSaturation(); #expect(session.hueSaturation == nil)
        session.choosePreset("warm"); await session.presetEdit?.renderTask?.value
        #expect(session.document != original && session.document?.layers.count == 1)
        session.finishPresetEditing(commit: false)
        #expect(session.document == original && session.history.undoCount == count)
        session.beginPixelPresets(); session.choosePreset("cool"); await session.presetEdit?.renderTask?.value
        #expect(session.finishPresetEditing(commit: true))
        let pixels = try AdjustmentLayerTests().pixels(#require(session.activeLayer?.asset?.image))
        #expect([pixels[3],pixels[7],pixels[11],pixels[15]] == [255,128,32,0])
        session.undo(); #expect(session.document == original)
        session.redo(); #expect(session.document != original)
    }

    @Test func pixelApplicationKeepsSixteenBitPrecisionAndSelection() async throws {
        let session = EditorSession(); session.createDocument(width: 2, height: 1)
        let context = try DeepLayer.context(width: 2, height: 1)
        let p = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        let source: [UInt16] = [12345,23456,34567,65535,12345,23456,34567,65535]
        for i in source.indices { p[i] = source[i] }
        session.insert(try DeepLayer.asset(#require(context.makeImage()), name: "16-bit"))
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0,y: 0,width: 1,height: 1),transform: nil),antialiased: false)
        session.beginPixelPresets(); session.choosePreset("cool"); await session.presetEdit?.renderTask?.value
        #expect(session.finishPresetEditing(commit: true))
        let deep = try #require(session.activeLayer?.asset?.deep)
        #expect(deep.bitsPerComponent == 16)
        let output = try DeepLayer.canonical(deep)
        let actual = try #require(output.data).assumingMemoryBound(to: UInt16.self)
        let expected = [12345.0*0.86,23456.0*0.97+65535*0.01,34567.0*0.9+65535*0.1]
        for i in 0..<3 { #expect(abs(Double(actual[i])-expected[i]) <= 2) }
        for i in 4..<8 { #expect(abs(Int(actual[i])-Int(source[i])) <= 2) }
        session.undo()
        session.document?.selection = DocumentSelection(path: CGMutablePath())
        session.beginPixelPresets()
        #expect(session.presetEdit == nil && !session.canAdjustColors)
        let unchanged = try DeepLayer.canonical(#require(session.activeLayer?.asset?.deep))
        let q = try #require(unchanged.data).assumingMemoryBound(to: UInt16.self)
        for i in source.indices { #expect(abs(Int(q[i])-Int(source[i])) <= 2) }
    }

    @Test func exportHonorsScopeOrderAndOpacityAndIgnoresMasks() async throws {
        let session = EditorSession(); session.createDocument(width: 2,height: 2)
        session.addAdjustment(.invert)
        let first = try #require(session.activeLayerID)
        session.beginPresetEditing(); session.choosePreset("warm"); session.finishPresetEditing(commit: true)
        let second = try #require(session.activeLayerID)
        session.document?.layers[0].opacity = 0.5
        session.document?.layers[0].mask = LayerMask.solid(revealing: false)
        let snapshot = try #require(session.projectSnapshot())
        let firstOnly = try await LUTExporter.shared.bake(snapshot, size: 3, title: "Selected", layers: [first])
        let parsed = try LUTFile.parse(firstOnly, filename: "test.cube")
        #expect(floats(parsed).enumerated().allSatisfy { $0.offset % 4 == 3 || abs($0.element-0.5)<0.00001 })
        let all = try await LUTExporter.shared.bake(snapshot, size: 3, title: "All")
        let reversed = try await LUTExporter.shared.bake(snapshot, size: 3, title: "All", layers: [second,first])
        #expect(all == reversed && all != firstOnly)
        for ids in [[UUID()],[],[first,first]] {
            await #expect(throws: LUTExportError.self) { try await LUTExporter.shared.bake(snapshot, size: 3, title: "Invalid", layers: ids) }
        }
        await #expect(throws: LUTExportError.self) { try await LUTExporter.shared.bake(snapshot, size: 130, title: "Invalid") }
        var nested = snapshot.manifest; nested.layers[0].parentID = UUID()
        await #expect(throws: LUTExportError.self) { try await LUTExporter.shared.bake(ProjectSnapshot(manifest: nested,images: snapshot.images), size: 3,title: "Nested",layers: [first]) }
    }
    @Test func previewOffPreparesAndCommitsLatestPixels() async throws {
        let session = EditorSession(); session.createDocument(width: 2, height: 2)
        session.insert(try AdjustmentLayerTests().image(PaletteColor(red: 0.5, green: 0.5, blue: 0.5)))
        let before = session.document, count = session.history.undoCount
        session.beginPixelPresets()
        session.presetEdit?.preview = false; session.applyPresetPreview()
        session.choosePreset("warm")
        #expect(session.presetEdit?.rendering == true)
        #expect(!session.finishPresetEditing(commit: true))
        await session.presetEdit?.renderTask?.value
        #expect(session.document == before)
        session.choosePreset("cool")
        await session.presetEdit?.renderTask?.value
        #expect(session.document == before)
        #expect(session.finishPresetEditing(commit: true))
        #expect(session.document != before && session.history.undoCount == count + 1)
        let pixel = try AdjustmentLayerTests().pixels(#require(session.activeLayer?.asset?.image))
        #expect(abs(Int(pixel[0])-110) <= 1 && abs(Int(pixel[2])-141) <= 1)
        session.undo(); #expect(session.document == before)
        session.beginPixelPresets(); session.presetEdit?.preview = false
        session.choosePreset("warm"); let task = session.presetEdit?.renderTask
        session.finishPresetEditing(commit: false); await task?.value
        #expect(session.document == before && session.presetEdit == nil)
    }

    @Test func newPresetUsesSelectionMaskAndCancelPreservesDocument() throws {
        let session = EditorSession(); session.createDocument(width: 2, height: 2)
        session.insert(try AdjustmentLayerTests().image(PaletteColor(red: 0.5, green: 0.5, blue: 0.5)))
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0,y: 0,width: 1,height: 2),transform: nil),antialiased: false)
        let before = session.document, count = session.history.undoCount
        session.beginPresetEditing(); session.choosePreset("warm")
        let image = try #require(session.activeLayer?.mask?.asset.image)
        let bytes = try #require(image.dataProvider?.data) as Data
        #expect(bytes[0] == 255 && bytes[1] == 0)
        session.finishPresetEditing(commit: false)
        #expect(session.document == before && session.history.undoCount == count)
        session.beginPresetEditing(); session.choosePreset("warm")
        #expect(session.finishPresetEditing(commit: true))
        #expect(session.activeLayer?.mask != nil && session.document?.selection == before?.selection)
        session.undo(); #expect(session.document == before)
        session.redo(); #expect(session.activeLayer?.mask != nil)
    }

    @Test func presetEditsPlacedMaskThroughSelectionAndKeepsImage() async throws {
        let session = EditorSession(); session.createDocument(width: 32, height: 32)
        session.insert(try AdjustmentLayerTests().image(PaletteColor(red: 0.5, green: 0.5, blue: 0.5)))
        session.addLayerMask()
        var placement = try #require(session.activeLayer?.transform)
        placement.origin = CGPoint(x: 10, y: 5)
        session.document?.layers[0].mask?.placement = placement
        session.document?.layers[0].mask?.isLinked = false
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 10,y: 5,width: 1,height: 2),transform: nil),antialiased: false)
        let before = session.document, count = session.history.undoCount
        #expect(session.isMaskSelected && session.canApplyPresets && !session.canAdjustColors)
        session.beginPixelPresets()
        session.presetEdit?.lookup = try LUTFile.generated(title: "Invert", size: 2) { SIMD3(repeating: 1) - $0 }
        session.applyPresetPreview(); await session.presetEdit?.renderTask?.value
        let mask = try #require(session.activeLayer?.mask)
        #expect(mask.isLinked == false && mask.placement == placement && mask.isEnabled)
        #expect(session.activeLayer?.asset?.image === before?.layers[0].asset?.image)
        #expect(mask.asset.image.width == 2 && LayerMask.isValid(mask.asset.image))
        let bytes = try #require(mask.asset.image.dataProvider?.data) as Data
        #expect(bytes[0] == 0 && bytes[1] == 255)
        #expect(session.finishPresetEditing(commit: true) && session.history.undoCount == count + 1)
        session.undo(); #expect(session.document == before)
        session.redo(); #expect(session.activeLayer?.mask == mask)
        session.beginPixelPresets(); session.choosePreset("cool")
        await session.presetEdit?.renderTask?.value
        session.finishPresetEditing(commit: false)
        #expect(session.activeLayer?.mask == mask)
    }

    @Test func presetCanEditAdjustmentLayerMaskWithoutImagePixels() async throws {
        let session = EditorSession(); session.createDocument(width: 2, height: 2)
        session.beginPresetEditing(); session.choosePreset("warm"); session.finishPresetEditing(commit: true)
        session.isMaskSelected = true
        #expect(session.activeLayer?.asset == nil && session.canApplyPresets)
        session.beginPixelPresets(); session.choosePreset("dayForNight")
        await session.presetEdit?.renderTask?.value
        #expect(session.finishPresetEditing(commit: true))
        let image = try #require(session.activeLayer?.mask?.asset.image)
        let bytes = try #require(image.dataProvider?.data) as Data
        #expect(abs(Int(bytes[0]) - 125) <= 1)
        #expect(session.activeLayer?.adjustment?.colorLookup?.title == "Warm Filter")
    }

    @Test func exportRejectsSpatialEffectsButAllowsSelectedColorLayers() async throws {
        for kind in [AdjustmentKind.gaussianBlur, .motionBlur, .grain, .addNoise, .progressiveBlur, .bloomGlow, .rgbSplit, .vignette, .lensEffects, .tonalContrast, .sharpen] {
            let session = EditorSession(); session.createDocument(width: 2, height: 2)
            session.addAdjustment(.invert)
            let color = try #require(session.activeLayerID)
            session.addAdjustment(kind); session.finishAdjustmentEditing(commit: true)
            let snapshot = try #require(session.projectSnapshot())
            await #expect(throws: LUTExportError.self) {
                _ = try await LUTExporter.shared.bake(snapshot, size: 3, title: "Spatial")
            }
            let cube = try await LUTExporter.shared.bake(snapshot, size: 3, title: "Color", layers: [color])
            #expect(try LUTFile.parse(cube, filename: "Color.cube").dimension == 3)
        }
    }

}
