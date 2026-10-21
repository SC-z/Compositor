import AppKit

extension EditorSession {
    func resetPresetColorSettings() {
        guard let edit = presetEdit else { return }
        let interpolation = edit.settings.interpolation, dither = edit.settings.dither ?? false
        edit.settings = .standard
        edit.settings.interpolation = interpolation; edit.settings.dither = dither
    }

    func choosePreset(_ choice: String) {
        guard let edit = presetEdit else { return }
        if choice == "load" { Task { await addPresetFiles(folder: false) }; return }
        if choice == "custom" { return }
        edit.task?.cancel(); edit.requestID = UUID(); edit.loading = false
        edit.choice = choice; edit.selection = nil; edit.error = nil
        resetPresetColorSettings()
        do {
            edit.lookup = choice == "none" ? nil : try LUTFile.builtin(choice)
            edit.name = edit.lookup.map { localized($0.title) } ?? localized("Presets")
            applyPresetPreview()
        } catch { edit.error = error.localizedDescription }
    }

    func beginPixelPresets() {
        guard canApplyPresets else { return }
        if gradientEdit != nil {
            Task { await commitGradient(); beginPixelPresets() }
            return
        }
        commitTransform(); cancelCrop(); cancelLasso()
        guard let layer = activeLayer, let document else { return }
        do {
            let clip = try selection?.clip(canvas: document.size)
            beginEdit("Apply Preset")
            let edit = PresetEdit(documentID: document.id, layer: layer, original: nil, selection: activeLayerID, insertionIndex: 0)
            edit.pixelOriginal = layer; edit.pixelSelection = clip; edit.pixelIsMask = isMaskSelected
            presetEdit = edit; adjustmentEditingID = layer.id
        } catch { importError = error.localizedDescription }
    }

    func applyPixelPresetPreview() {
        guard let edit = presetEdit, let original = edit.pixelOriginal,
              let index = document?.layers.firstIndex(where: { $0.id == original.id }),
              let asset = edit.pixelIsMask ? original.mask?.asset : original.asset else { return }
        if edit.lookup == nil || edit.error != nil {
            edit.renderTask?.cancel(); edit.renderID = UUID(); edit.rendering = false
            document?.layers[index] = original; brushRevision += 1
            return
        }
        if !edit.preview { document?.layers[index] = original; brushRevision += 1 }
        if edit.renderedLookup === edit.lookup, edit.renderedSettings == edit.settings, let made = edit.renderedAsset {
            edit.renderTask?.cancel(); edit.renderID = UUID(); edit.rendering = false
            guard edit.preview else { return }
            var layer = original
            if edit.pixelIsMask { layer.mask = original.mask?.replacing(made) }
            else { layer.asset = made; layer.text = nil; layer.shape = nil }
            document?.layers[index] = layer; brushRevision += 1; return
        }
        guard let lookup = edit.lookup else { return }
        edit.renderTask?.cancel(); let request = UUID(); edit.renderID = request; edit.rendering = true
        // Compute even with Preview off, so OK can only commit a finished result.
        let settings = edit.settings, selection = edit.pixelSelection, mask = edit.pixelIsMask
        let transform = mask ? original.maskTransform : original.transform
        edit.renderTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let deep = mask ? nil : try DeepLayer.flattened(asset)
                    var source = deep ?? asset.image
                    if mask, source.width == 1, source.height == 1 {
                        source = try Self.expandedUniformMask(source,
                            width: original.asset?.image.width ?? Int(original.size.width.rounded()),
                            height: original.asset?.image.height ?? Int(original.size.height.rounded()))
                    }
                    var result = try lookup.apply(source, sixteenBit: deep != nil, settings: settings, isMask: mask)
                    try Task.checkCancellation()
                    if let selection {
                        result = try PixelAdjust.blend(result, over: source, through: selection,
                            pixelToDocument: BrushRaster.pixelToDocument(transform, width: source.width, height: source.height),
                            isMask: mask, sixteenBit: deep != nil)
                    }
                    if mask { return try LayerMask.asset(from: result) }
                    return deep != nil ? try DeepLayer.asset(result, name: asset.name)
                        : ImportedImage(image: result, thumbnail: try PixelAdjust.thumbnail(of: result), name: asset.name)
                }
                let made = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.presetEdit === edit, edit.renderID == request else { return }
                edit.rendering = false; edit.renderedAsset = made; edit.renderedLookup = lookup; edit.renderedSettings = settings
                self.applyPixelPresetPreview()
            } catch {
                guard let self, self.presetEdit === edit, edit.renderID == request else { return }
                edit.rendering = false; edit.error = error.localizedDescription
            }
        }
    }
}
