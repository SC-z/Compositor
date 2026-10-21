import AppKit
import Testing
@testable import Compositor

@MainActor struct PresetTests {
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.presetLibrary = PresetLibrary()
        session.createDocument(width: 2, height: 2)
        session.insert(try AdjustmentLayerTests().image(PaletteColor(red: 1, green: 0, blue: 0)))
        return session
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Presets-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(ColorLookupTests.table().utf8).write(to: url.appendingPathComponent("A.cube"))
        try Data(ColorLookupTests.table(swap: true).utf8).write(to: url.appendingPathComponent("B.cube"))
        return url
    }

    @Test func continuousPreviewCommitsOneLayerAndOneUndoEntry() async throws {
        let session = try session(), fixtures = AdjustmentLayerTests(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try session.presetLibrary.add(PresetFile.collect([root]))
        let original = session.document, historyCount = session.history.undoCount
        session.beginPresetEditing()
        #expect(session.document == original && !session.canStartProjectOperation && !session.canEditLayers)
        session.selectPreset(root.appendingPathComponent("A.cube")); await session.presetEdit?.task?.value
        session.selectPreset(root.appendingPathComponent("B.cube")); await session.presetEdit?.task?.value
        #expect(session.document?.layers.count == 2 && !session.canUndo)
        #expect(Array(try await fixtures.rendered(session).prefix(4)) == [0, 255, 0, 255])
        session.presetEdit?.preview = false; session.applyPresetPreview()
        #expect(session.document == original)
        session.presetEdit?.preview = true; session.applyPresetPreview()
        #expect(session.document?.layers.count == 2)
        session.presetEdit?.preview = false; session.applyPresetPreview()
        #expect(session.finishPresetEditing(commit: true))
        #expect(session.presetEdit == nil && session.adjustmentEditingID == nil)
        #expect(session.history.undoCount == historyCount + 1 && session.canStartProjectOperation)
        #expect(Array(try await fixtures.rendered(session).prefix(4)) == [0, 255, 0, 255])
        session.undo(); #expect(session.document == original)
        session.redo(); #expect(session.document?.layers.count == 2)
    }

    @Test func existingPresetCancelPreservesMaskOpacityNameAndSelection() async throws {
        let session = try session(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try session.presetLibrary.add(PresetFile.collect([root]))
        session.addAdjustment(.colorLookup, colorLookup: try ColorLookup.read(from: root.appendingPathComponent("A.cube")))
        let id = try #require(session.activeLayerID)
        session.document?.layers[1].name = "Custom name"
        session.document?.layers[1].opacity = 0.4
        session.document?.layers[1].mask = LayerMask.solid(revealing: true)
        session.document?.layers[1].blendMode = .multiply
        session.activeLayerID = session.document?.layers[0].id
        let original = session.document, originalSelection = session.activeLayerID, count = session.history.undoCount
        session.adjustmentEditingID = id
        await session.beginAdjustmentEditing(id)
        session.selectPreset(root.appendingPathComponent("B.cube")); await session.presetEdit?.task?.value
        #expect(session.document?.layers[1].opacity == 0.4 && session.document?.layers[1].mask == original?.layers[1].mask)
        session.selectPreset(nil)
        #expect(session.document == original)
        session.selectPreset(root.appendingPathComponent("B.cube")); await session.presetEdit?.task?.value
        #expect(session.finishAdjustmentEditing(commit: false))
        #expect(session.document == original && session.activeLayerID == originalSelection)
        #expect(session.history.undoCount == count)
    }

    @Test func newestSelectionWinsAndClosedPreviewCannotReappear() async throws {
        let session = try session(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try session.presetLibrary.add(PresetFile.collect([root]))
        let original = session.document
        session.beginPresetEditing()
        session.selectPreset(root.appendingPathComponent("A.cube")); let first = session.presetEdit?.task
        session.selectPreset(root.appendingPathComponent("B.cube")); let last = session.presetEdit?.task
        await first?.value; await last?.value
        #expect(session.presetEdit?.selection?.lastPathComponent == "B.cube")
        #expect(Array(try await AdjustmentLayerTests().rendered(session).prefix(4)) == [0, 255, 0, 255])
        session.finishPresetEditing(commit: false)
        session.beginPresetEditing()
        let fresh = root.appendingPathComponent("C.cube")
        try Data(ColorLookupTests.table(size: 33, swap: true).utf8).write(to: fresh)
        try session.presetLibrary.add([PresetFile(url: fresh, accessURL: fresh)])
        session.selectPreset(fresh); let pending = session.presetEdit?.task
        session.finishPresetEditing(commit: false)
        await pending?.value
        #expect(session.document == original && session.presetEdit == nil && session.canStartProjectOperation)
    }

    @Test func badFilesRestoreOriginalAndCannotBeCommitted() async throws {
        let session = try session(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("Bad.cube")
        try Data("LUT_3D_SIZE 2\n0 0 0".utf8).write(to: bad)
        try session.presetLibrary.add(PresetFile.collect([root]))
        let original = session.document, count = session.history.undoCount
        session.beginPresetEditing()
        session.selectPreset(root.appendingPathComponent("B.cube")); await session.presetEdit?.task?.value
        session.selectPreset(bad); await session.presetEdit?.task?.value
        #expect(session.presetEdit?.error != nil && session.document == original)
        #expect(!session.finishPresetEditing(commit: true))
        session.finishPresetEditing(commit: false)
        #expect(session.history.undoCount == count)
    }

    @Test func folderDiscoveryDeduplicatesAndCacheIsBounded() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(ColorLookupTests.table().utf8).write(to: nested.appendingPathComponent("C.CUBE"))
        try Data().write(to: nested.appendingPathComponent("skip.txt"))
        let library = PresetLibrary()
        try library.add(PresetFile.collect([root, root.appendingPathComponent("A.cube")]))
        #expect(library.files.count == 3)
        let lookup = try ColorLookup.read(from: root.appendingPathComponent("A.cube"))
        for n in 0..<17 { library.remember(lookup, for: root.appendingPathComponent("\(n).cube")) }
        #expect(library.cached(root.appendingPathComponent("0.cube")) == nil)
        #expect(library.cached(root.appendingPathComponent("16.cube")) === lookup)
        let tooMany = (0...10_000).map { PresetFile(url: root.appendingPathComponent("extra\($0).cube"), accessURL: root) }
        #expect(throws: PresetError.self) { try library.add(tooMany) }
        #expect(library.files.count == 3)
    }

    @Test func presetPanelSurvivesLayoutAndWindowCloseCancels() throws {
        let session = try session(), before = session.document
        session.beginPresetEditing()
        let panel = FloatingPanelController(name: "presetTestPanel")
        panel.onClose = { session.finishPresetEditing(commit: false) }
        panel.show(title: "Presets", content: PresetsPanel(session: session))
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "presetTestPanel" })
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.isVisible && window.frame.width >= 350 && window.frame.height >= 200)
        if let screen = window.screen { #expect(window.frame.height <= screen.visibleFrame.height) }
        if let output = ProcessInfo.processInfo.environment["COMPOSITOR_PANEL_SCREENSHOT"],
           let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
        func picker(in view: NSView) -> NSPopUpButton? {
            if let picker = view as? NSPopUpButton { return picker }
            return view.subviews.compactMap { picker(in: $0) }.first
        }
        let choice = try #require(window.contentView.flatMap { picker(in: $0) })
        #expect(choice.numberOfItems == 10)
        choice.selectItem(at: 2)
        _ = NSApp.sendAction(try #require(choice.action), to: choice.target, from: choice)
        #expect(session.presetEdit?.choice == "warm")
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        choice.keyDown(with: down)
        #expect(session.presetEdit?.choice == "cool")
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        scroll.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        choice.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        #expect(session.presetEdit?.choice == "tealOrange")
        window.performClose(nil)
        #expect(session.presetEdit == nil && session.document == before && session.history.canUndo)
    }
}
