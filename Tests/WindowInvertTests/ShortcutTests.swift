import Carbon
import XCTest
@testable import WindowInvert

final class ShortcutTests: XCTestCase {
    func testDefaultShortcuts() {
        let expected: [(ShortcutAction, Int, Int)] = [
            (.invertWindow, kVK_ANSI_8, optionKey),
            (.invertContent, kVK_ANSI_9, optionKey),
            (.switchStyle, kVK_ANSI_0, optionKey | cmdKey),
            (.cycleContrast, kVK_ANSI_0, optionKey | shiftKey),
            (.stopAll, kVK_ANSI_0, optionKey),
        ]
        for (action, key, modifiers) in expected {
            XCTAssertEqual(action.defaultCombo, KeyCombo(keyCode: UInt32(key), modifiers: UInt32(modifiers)))
            XCTAssertTrue(action.defaultCombo.isValidGlobalShortcut)
        }
    }

    func testDefaultsAndHotKeyIDsAreDistinct() {
        XCTAssertEqual(Set(ShortcutAction.allCases.map { $0.defaultCombo.storageString }).count, 5)
        XCTAssertEqual(Set(ShortcutAction.allCases.map(\.hotKeyID)).count, 5)
        XCTAssertEqual(ShortcutAction.stopAll.hotKeyID, 4)
        XCTAssertEqual(ShortcutAction.cycleContrast.hotKeyID, 5)
    }

    func testContrastCyclesInMenuOrderAndWrapsAround() {
        XCTAssertEqual(Contrast.high.next, .medium)
        XCTAssertEqual(Contrast.medium.next, .soft)
        XCTAssertEqual(Contrast.soft.next, .high)
    }
}
