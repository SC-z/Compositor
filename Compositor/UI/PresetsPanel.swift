import SwiftUI

struct PresetsPanel: View {
    @Bindable var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("3D LUT File")
                PresetPicker(choice: session.presetEdit?.choice ?? "none", custom: session.presetEdit?.lookup.map {
                    "\(session.presetEdit?.name ?? $0.title) (\($0.dimension)³)"
                }, choose: session.choosePreset)
                .frame(height: 26).accessibilityLabel("3D LUT File")
            }
            Picker("Interpolation", selection: Binding(get: { session.presetEdit?.settings.interpolation ?? .trilinear }, set: {
                session.presetEdit?.settings.interpolation = $0; session.applyPresetPreview()
            })) {
                ForEach(LUTInterpolation.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.radioGroup).horizontalRadioGroupLayout()
            Toggle("Dither", isOn: Binding(get: { session.presetEdit?.settings.dither ?? false }, set: {
                session.presetEdit?.settings.dither = $0; session.applyPresetPreview()
            }))
            if session.presetEdit?.settings.hasLegacyColorConversion == true {
                Text("This project retains its earlier color-space settings. Choosing another LUT uses PhotoCraft-compatible settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Preview", isOn: Binding(get: { session.presetEdit?.preview ?? true }, set: {
                session.presetEdit?.preview = $0; session.applyPresetPreview()
            }))
            if session.presetEdit?.loading == true || session.presetEdit?.rendering == true {
                HStack { ProgressView().controlSize(.small); Text("Loading…") }
            }
            if let error = session.presetEdit?.error {
                Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Cancel") { session.finishPresetEditing(commit: false) }.configuredNativeShortcut(.escape)
                Spacer()
                Button("OK") { session.finishPresetEditing(commit: true) }
                    .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(session.presetEdit?.loading == true || session.presetEdit?.rendering == true
                              || session.presetEdit?.choosingFiles == true || session.presetEdit?.error != nil)
            }
        }.padding(20).frame(width: 440).fixedSize(horizontal: false, vertical: true)
    }
}

/// The native picker also cycles while the pointer is over it, without opening the menu.
private struct PresetPicker: NSViewRepresentable {
    var choice: String
    var custom: String?
    var choose: (String) -> Void

    func makeNSView(context: Context) -> PickerButton {
        let view = PickerButton(frame: .zero, pullsDown: false)
        view.target = view; view.action = #selector(PickerButton.picked)
        return view
    }
    func updateNSView(_ view: PickerButton, context: Context) {
        view.choose = choose
        let entries = [("load", localized("Load 3D LUT…")), ("none", localized("None"))]
            + LUTFile.builtins.map { ($0.id, localized($0.title)) } + (custom.map { [("custom", $0)] } ?? [])
        if view.itemArray.map(\.title) != entries.map({ $0.1 }) {
            view.removeAllItems()
            for (id, title) in entries { view.addItem(withTitle: title); view.lastItem?.representedObject = id }
        }
        view.selectItem(at: entries.firstIndex(where: { $0.0 == choice }) ?? 1)
    }
    final class PickerButton: NSPopUpButton {
        var choose: ((String) -> Void)?
        var lastScroll: TimeInterval = 0
        @objc func picked() { if let id = selectedItem?.representedObject as? String { choose?(id) } }
        override func scrollWheel(with event: NSEvent) {
            guard abs(event.scrollingDeltaY) > 0, event.timestamp - lastScroll > 0.08 else { return }
            lastScroll = event.timestamp; step(event.scrollingDeltaY < 0 ? 1 : -1)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 125 || event.keyCode == 126 { step(event.keyCode == 125 ? 1 : -1) }
            else { super.keyDown(with: event) }
        }
        private func step(_ offset: Int) {
            let next = min(9, max(1, indexOfSelectedItem + offset))
            guard next != indexOfSelectedItem else { return }
            selectItem(at: next); picked()
        }
    }
}
