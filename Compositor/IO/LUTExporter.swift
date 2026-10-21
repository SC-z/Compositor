import AppKit
import CoreImage
import UniformTypeIdentifiers
import SwiftUI

nonisolated enum LUTExportError: LocalizedError {
    case size, selection, empty, spatial([String])
    var errorDescription: String? {
        switch self {
        case .size: localized("LUT grid size must be an integer from 2 to 129.")
        case .selection: localized("Select visible adjustment layers outside groups. Duplicate layer selections are not allowed.")
        case .empty: localized("There are no visible adjustment layers outside groups to export.")
        case .spatial(let names): localized("LUT export cannot include blur, grain or noise. Hide these layers or select only color adjustments:") + "\n" + names.joined(separator: ", ")
        }
    }
}

actor LUTExporter {
    static let shared = LUTExporter()

    func bake(_ snapshot: ProjectSnapshot, size: Int = 33, title: String, layers ids: [UUID]? = nil) throws -> Data {
        guard (2...129).contains(size) else { throw LUTExportError.size }
        let records = snapshot.manifest.layers
        if let ids {
            guard !ids.isEmpty, Set(ids).count == ids.count,
                  ids.allSatisfy({ id in records.contains { $0.id == id && $0.isVisible && $0.parentID == nil && $0.adjustment != nil } }) else { throw LUTExportError.selection }
        }
        let layers = records.filter { $0.isVisible && $0.parentID == nil && $0.adjustment != nil && (ids == nil || ids!.contains($0.id)) }
        guard !layers.isEmpty else { throw LUTExportError.empty }
        let spatial = layers.filter { $0.adjustment?.kind.canExportLUT == false }
        guard spatial.isEmpty else { throw LUTExportError.spatial(spatial.map(\.name)) }
        let w = size*size, h = size, step = Float(1) / Float(size-1)
        var pixels = [Float](); pixels.reserveCapacity(size*size*size*4)
        for g in 0..<size { for b in 0..<size { for r in 0..<size {
            pixels.append(contentsOf: [Float(r)*step,Float(g)*step,Float(b)*step,1])
        } } }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        var image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: w*16, size: bounds.size, format: .RGBAf, colorSpace: nil)
        let mapping = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h))
        for layer in layers {
            try Task.checkCancellation()
            guard let adjustment = layer.adjustment else { throw ExportError.render }
            let changed: CIImage
            if adjustment.kind == .invert { changed = image.applyingFilter("CIColorInvert") }
            else if let result = GPUAdjustment.apply(adjustment, to: image, scale: 1, mapping: mapping) { changed = result }
            else { throw ExportError.render }
            image = GPUBlend.blend(GPUBlend.faded(changed, layer.opacity ?? 1), over: image, mode: layer.blendMode ?? .normal).cropped(to: bounds)
        }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
        context.render(image, toBitmap: &pixels, rowBytes: w*16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
        var result = "TITLE \"\(safeTitle)\"\n# Created by Compositor\nLUT_3D_SIZE \(size)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let i = (g*w+b*size+r)*4
            let c = (0..<3).map { min(1,max(0,pixels[i+$0])) }
            guard c.allSatisfy(\.isFinite) else { throw ExportError.render }
            result += String(format: "%.6f %.6f %.6f\n", locale: Locale(identifier: "en_US_POSIX"), c[0], c[1], c[2])
        } } }
        return Data(result.utf8)
    }
}

struct LUTExportOptions { var size = 33; var title = "Preset"; var selected = false }

private struct LUTExportSheet: View {
    @State var options: LUTExportOptions
    let done: (LUTExportOptions?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export LUT…").font(.headline)
            TextField("Title", text: $options.title)
            TextField("Grid points", value: $options.size, format: .number).help("2–129; default 33")
            Picker("Export scope", selection: $options.selected) {
                Text("All visible adjustment layers").tag(false)
                Text("Selected adjustment layers").tag(true)
            }
            Text("Exports adjustment layers outside groups in document order. Masks and clipping are excluded; opacity and blend modes are included.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Blur, grain and noise cannot be exported as a LUT.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { done(options) }.keyboardShortcut(.defaultAction).disabled(!(2...129).contains(options.size))
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 430)
    }
}

extension ProjectController {
    func exportLUT() async {
        guard canStart, let window, let snapshot = session.projectSnapshot() else { return }
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        let ids = session.selectedLayerIDs
        let selected = !ids.isEmpty && ids.allSatisfy { id in snapshot.manifest.layers.contains { $0.id == id && $0.parentID == nil && $0.isVisible && $0.adjustment != nil } }
        let initial = LUTExportOptions(title: window.title.replacingOccurrences(of: ".comp", with: ""), selected: selected)
        let options: LUTExportOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.contentViewController = NSHostingController(rootView: LUTExportSheet(options: initial) { options in
                window.endSheet(sheet); sheet.orderOut(nil); sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.nameFieldStringValue = "\(options.title.isEmpty ? "Preset" : options.title).cube"
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await LUTExporter.shared.bake(snapshot, size: options.size, title: options.title, layers: options.selected ? Array(ids) : nil)
            try data.write(to: url, options: .atomic)
        } catch { session.importError = error.localizedDescription }
    }
}
