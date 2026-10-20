import Carbon
import Foundation
import Testing
@testable import Sniplet

struct ShortcutPolicyTests {
    private func error(_ binding: ShortcutBinding, others: [ShortcutBinding] = [], system: [ShortcutBinding] = [], menu: [ShortcutBinding] = []) -> String? {
        ShortcutPolicy.validationError(binding, otherBindings: others, systemBindings: system, menuBindings: menu)
    }

    @Test func requiresCommandOrControlAndAnActualNonEscapeKey() {
        for binding in [ShortcutBinding(keyCode: 21, modifiers: 0),
                        ShortcutBinding(keyCode: 21, modifiers: UInt32(optionKey | shiftKey)),
                        ShortcutBinding(keyCode: 53, modifiers: UInt32(cmdKey)),
                        ShortcutBinding(keyCode: 55, modifiers: UInt32(cmdKey)),
                        ShortcutBinding(keyCode: 200, modifiers: UInt32(controlKey)),
                        ShortcutBinding(keyCode: 21, modifiers: UInt32(cmdKey) | (1 << 30))] {
            #expect(error(binding) != nil)
        }
        #expect(error(ShortcutBinding(keyCode: 21, modifiers: UInt32(controlKey))) == nil)
        #expect(error(ShortcutBinding(keyCode: 21, modifiers: UInt32(cmdKey))) == nil)
    }

    @Test func duplicateAndEnabledSystemAndMenuBindingsAreRejectedExactly() {
        let candidate = ShortcutBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey))
        let different = ShortcutBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))
        #expect(error(candidate, others: [candidate]) != nil)
        #expect(error(candidate, system: [candidate]) != nil)
        #expect(error(candidate, menu: [candidate]) != nil)
        #expect(error(candidate, others: [different], system: [different], menu: [different]) == nil)
    }

    @Test func persistenceRoundTripAndClearMarker() throws {
        let binding = ShortcutBinding.defaultBinding(for: .region)
        let data = try JSONEncoder().encode(Optional(binding))
        #expect(try JSONDecoder().decode(ShortcutBinding?.self, from: data) == binding)
        #expect(try JSONDecoder().decode(ShortcutBinding?.self, from: Data("null".utf8)) == nil)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["keyCode", "modifiers"])
    }
}
