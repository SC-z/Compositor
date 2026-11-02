import AppKit
import Observation
import UniformTypeIdentifiers

nonisolated struct PresetFile: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let accessURL: URL
    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL, accessURL: URL) {
        self.url = url.standardizedFileURL
        self.accessURL = accessURL
    }

    func read() throws -> ColorLookup {
        let access = accessURL.startAccessingSecurityScopedResource()
        defer { if access { accessURL.stopAccessingSecurityScopedResource() } }
        return try ColorLookup.read(from: url, photocraft: true)
    }

    static func collect(_ urls: [URL]) throws -> [Self] {
        var found: [URL: Self] = [:]
        for root in urls {
            try Task.checkCancellation()
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let directory = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if !directory {
                if LUTFile.extensions.contains(root.pathExtension.lowercased()) {
                    let file = Self(url: root, accessURL: root)
                    found[file.url] = file
                }
                continue
            }
            var readError: Error?
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in readError = error; return false }) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case let file as URL in files {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { files.skipDescendants(); continue }
                if values.isRegularFile == true, LUTFile.extensions.contains(file.pathExtension.lowercased()) {
                    let entry = Self(url: file, accessURL: root)
                    found[entry.url] = entry
                    guard found.count <= 10_000 else { throw PresetError.tooMany }
                }
            }
            if let readError { throw readError }
        }
        return Array(found.values)
    }
}

nonisolated enum PresetError: LocalizedError {
    case tooMany, empty
    var errorDescription: String? {
        switch self {
        case .tooMany: localized("Add up to 10,000 presets at a time.")
        case .empty: localized("No .cube presets were found.")
        }
    }
}

// Serialize parsing so rapid selection cannot load several large tables at once.
actor PresetLoader {
    static let shared = PresetLoader()
    func read(_ file: PresetFile) throws -> ColorLookup {
        try Task.checkCancellation()
        return try file.read()
    }
}

/// File choices last for this app session; only the applied table is embedded in a project.
@Observable final class PresetLibrary {
    static let shared = PresetLibrary()
    private(set) var files: [PresetFile] = []
    @ObservationIgnored private var cache: [(URL, ColorLookup)] = []

    func add(_ files: [PresetFile]) throws {
        var all = Dictionary(uniqueKeysWithValues: self.files.map { ($0.url, $0) })
        for file in files { all[file.url] = file }
        guard all.count <= 10_000 else { throw PresetError.tooMany }
        self.files = all.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        let reloaded = Set(files.map(\.url))
        cache.removeAll { reloaded.contains($0.0) }
    }

    func cached(_ url: URL) -> ColorLookup? {
        guard let index = cache.firstIndex(where: { $0.0 == url }) else { return nil }
        let entry = cache.remove(at: index)
        cache.insert(entry, at: 0)
        return entry.1
    }

    func remember(_ lookup: ColorLookup, for url: URL) {
        cache.removeAll { $0.0 == url }
        cache.insert((url, lookup), at: 0)
        while cache.count > 16 || cache.reduce(0, { $0 + $1.1.cube.count }) > 64 * 1024 * 1024 { cache.removeLast() }
    }
}

@Observable final class PresetEdit {
    let documentID: UUID
    let layer: ImageLayer
    let original: ImageLayer?
    let originalSelection: UUID?
    let insertionIndex: Int
    var choice = "none"
    var selection: URL?
    var lookup: ColorLookup?
    var settings: LUTSettings
    var name: String
    var pixelOriginal: ImageLayer?
    var pixelSource: ImageLayer?
    var pixelIsMask = false
    var pixelSelection: SelectionClip?
    var renderedAsset: ImportedImage?
    var renderedLookup: ColorLookup?
    var renderedSettings: LUTSettings?
    var rendering = false
    @ObservationIgnored var renderTask: Task<Void, Never>?
    @ObservationIgnored var renderID = UUID()
    var preview = true
    var loading = false
    var choosingFiles = false
    var error: String?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var discoveryTask: Task<[PresetFile], Error>?
    @ObservationIgnored var requestID = UUID()

    init(documentID: UUID, layer: ImageLayer, original: ImageLayer?, selection: UUID?, insertionIndex: Int) {
        self.documentID = documentID; self.layer = layer; self.original = original
        originalSelection = selection; self.insertionIndex = insertionIndex
        lookup = original?.adjustment?.colorLookup
        settings = original?.adjustment?.resolvedLookupSettings ?? LUTSettings.standard
        name = original?.name ?? localized("Presets")
        choice = lookup.flatMap { lookup in LUTFile.builtins.first { $0.title == lookup.title && (try? LUTFile.builtin($0.id)) == lookup }?.id } ?? (lookup == nil ? "none" : "custom")
    }
}

extension EditorSession {
    func beginPresetEditing(_ id: UUID? = nil) {
        guard presetEdit == nil, canEditLayers || (id != nil && adjustmentEditingID == id), let document else { return }
        let original = id.flatMap { id in document.layers.first { $0.id == id && $0.adjustment?.kind == .colorLookup } }
        guard id == nil || original != nil, original != nil || document.layers.count < 10_000 else { return }
        var layer = original ?? ImageLayer(name: "Presets", blankSize: document.size)
        if original == nil {
            layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
            do {
                if let selection {
                    let width = Int(document.size.width), height = Int(document.size.height)
                    let image = try PixelAdjust.coverage(selection.clip(canvas: document.size), width: width, height: height,
                        pixelToDocument: BrushRaster.pixelToDocument(layer.transform, width: width, height: height))
                    layer.mask = LayerMask(asset: try LayerMask.asset(from: image))
                } else { layer.mask = LayerMask.solid(revealing: true) }
            } catch { importError = error.localizedDescription; return }
        }
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        beginEdit(original == nil ? "Apply Preset" : "Change Preset")
        presetEdit = PresetEdit(documentID: document.id, layer: layer, original: original, selection: activeLayerID, insertionIndex: index)
        adjustmentEditingID = layer.id
    }

    func addPresetFiles(folder: Bool) async {
        guard let edit = presetEdit, !edit.choosingFiles else { return }
        edit.choosingFiles = true
        defer { edit.choosingFiles = false }
        let panel = NSOpenPanel()
        panel.title = localized(folder ? "Add Preset Folder…" : "Add Presets…")
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        if !folder { panel.allowedContentTypes = LUTFile.extensions.map { UTType(filenameExtension: $0) ?? .data } }
        guard await panel.begin() == .OK, presetEdit === edit else { return }
        let urls = panel.urls
        let worker = Task.detached(priority: .userInitiated) { try PresetFile.collect(urls) }
        edit.discoveryTask = worker
        defer { edit.discoveryTask = nil }
        do {
            let files = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard presetEdit === edit else { return }
            guard !files.isEmpty else { throw PresetError.empty }
            try presetLibrary.add(files)
            edit.error = nil
            let added = Set(files.map(\.url))
            if let first = presetLibrary.files.first(where: { added.contains($0.url) }) {
                selectPreset(first.url)
            }
        } catch { if presetEdit === edit { edit.error = error.localizedDescription } }
    }

    func selectPreset(_ url: URL?) {
        guard let edit = presetEdit else { return }
        let url = url?.standardizedFileURL
        edit.task?.cancel()
        let request = UUID(); edit.requestID = request
        edit.selection = url; edit.error = nil
        if url != nil { edit.choice = "custom"; resetPresetColorSettings() }
        if url == nil {
            edit.lookup = edit.original?.adjustment?.colorLookup
            edit.settings = edit.original?.adjustment?.resolvedLookupSettings ?? LUTSettings.standard
            edit.name = edit.original?.name ?? localized("Presets")
            edit.loading = false
            applyPresetPreview()
            return
        }
        guard let file = presetLibrary.files.first(where: { $0.url == url }) else { return }
        func accept(_ lookup: ColorLookup) {
            edit.lookup = lookup
            edit.name = file.url.lastPathComponent
            edit.loading = false
            applyPresetPreview()
        }
        if let cached = presetLibrary.cached(file.url) { accept(cached); return }
        edit.loading = true
        let worker = Task.detached(priority: .userInitiated) { try await PresetLoader.shared.read(file) }
        edit.task = Task { [weak self] in
            do {
                let lookup = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.presetEdit === edit, edit.requestID == request else { return }
                self.presetLibrary.remember(lookup, for: file.url)
                accept(lookup)
            } catch {
                guard let self, !Task.isCancelled, self.presetEdit === edit, edit.requestID == request else { return }
                edit.loading = false; edit.lookup = nil; edit.error = error.localizedDescription
                self.applyPresetPreview()
            }
        }
    }

    func applyPresetPreview() {
        guard let edit = presetEdit, document?.id == edit.documentID else { return }
        if edit.pixelOriginal != nil { applyPixelPresetPreview(); return }
        var layer: ImageLayer? = edit.original
        if edit.preview, edit.error == nil {
            var changed = edit.layer
            changed.adjustment = LayerAdjustment(kind: .colorLookup, colorLookup: edit.lookup)
            changed.adjustment?.lookupSettings = edit.settings == LUTSettings() ? nil : edit.settings
            changed.name = edit.name
            layer = changed
        }
        if let index = document?.layers.firstIndex(where: { $0.id == edit.layer.id }) {
            if let layer { document?.layers[index] = layer }
            else { document?.layers.remove(at: index) }
        } else if let layer {
            let index = min(edit.insertionIndex, document?.layers.count ?? 0)
            document?.layers.insert(layer, at: index)
            if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        }
        activeLayerID = layer == nil ? edit.originalSelection : edit.layer.id
        brushRevision += 1
    }

    @discardableResult
    func finishPresetEditing(commit: Bool) -> Bool {
        guard let edit = presetEdit else { return false }
        if commit, edit.loading || edit.rendering || edit.choosingFiles || edit.error != nil { return false }
        edit.task?.cancel(); edit.discoveryTask?.cancel(); edit.renderTask?.cancel(); edit.renderID = UUID(); edit.requestID = UUID()
        edit.preview = commit
        if !commit, let original = edit.pixelOriginal,
           let index = document?.layers.firstIndex(where: { $0.id == original.id }) {
            document?.layers[index] = original; brushRevision += 1
        } else { applyPresetPreview() }
        if commit, edit.error != nil { return false }
        if !commit { activeLayerID = edit.originalSelection }
        endEdit()
        presetEdit = nil
        adjustmentEditingID = nil
        canvasFocusRequest += 1
        return true
    }
}
