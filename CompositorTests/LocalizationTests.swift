import AppKit
import Testing
@testable import Compositor

@MainActor
struct LocalizationTests {
    @Test func translatedBlendTitleKeepsItsStoredValue() throws {
        let session = EditorSession()
        session.createDocument(width: 16, height: 16)
        let coordinator = BlendModePicker(session: session).makeCoordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItem(withTitle: "正片叠底")
        let item = try #require(button.lastItem)
        item.representedObject = LayerBlendMode.multiply.rawValue
        let menu = try #require(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.choose(button)
        #expect(session.activeLayer?.blendMode == .multiply)
        let encoded = try JSONEncoder().encode(session.activeLayer?.blendMode)
        #expect(String(data: encoded, encoding: .utf8) == "\"Multiply\"")
    }
}
