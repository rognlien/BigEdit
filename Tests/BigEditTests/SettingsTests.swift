import AppKit
import XCTest
@testable import BigEdit

final class SettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "BigEditSettingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsWhenNothingIsStored() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.appearance, .system)
        XCTAssertNil(settings.fontFamily)
        XCTAssertEqual(settings.fontSize, ViewportView.defaultFontSize)
        XCTAssertTrue(settings.loadsRemoteImages)
    }

    func testChangesPersistAndAreReported() {
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }

        settings.appearance = .dark
        settings.fontFamily = "Menlo"
        settings.fontSize = 15
        settings.loadsRemoteImages = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.fontFamily, "Menlo")
        XCTAssertEqual(reloaded.fontSize, 15)
        XCTAssertFalse(reloaded.loadsRemoteImages)
    }

    func testFontSizeKeepsTheKeyZoomAlreadyUsed() {
        defaults.set(16.0, forKey: "BigEditFontSize")

        XCTAssertEqual(AppSettings(defaults: defaults).fontSize, 16)
    }

    func testAppearanceMapsToTheForcedAppearance() {
        XCTAssertNil(AppSettings.Appearance.system.appearance)
        XCTAssertEqual(AppSettings.Appearance.light.appearance?.name, .aqua)
        XCTAssertEqual(AppSettings.Appearance.dark.appearance?.name, .darkAqua)
    }

    func testOnlyMonospacedFamiliesAreOffered() {
        let families = EditorFont.monospacedFamilies()

        XCTAssertTrue(families.contains("Menlo"))
        XCTAssertFalse(families.contains("Helvetica"))
        for family in families {
            XCTAssertTrue(EditorFont.font(family: family, size: 12).isFixedPitch, family)
        }
    }

    func testMissingOrProportionalFamilyFallsBackToSystemMonospaced() {
        let system = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        XCTAssertEqual(EditorFont.font(family: nil, size: 12), system)
        XCTAssertEqual(EditorFont.font(family: "No Such Font", size: 12), system)
        XCTAssertEqual(EditorFont.font(family: "Helvetica", size: 12), system)
    }

    func testViewportTakesTheFamilyAndBoldFace() {
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        viewport.setEditorFont(family: "Menlo", size: 14)

        XCTAssertEqual(viewport.font.familyName, "Menlo")
        XCTAssertEqual(viewport.font.pointSize, 14)
        XCTAssertTrue(viewport.boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(viewport.characterWidth, ViewportView.characterWidth(for: viewport.font))
    }

    func testInvisiblesAreHiddenUntilShownAndTheChoiceIsKept() {
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }

        XCTAssertFalse(settings.showsInvisibles)
        settings.showsInvisibles = true

        XCTAssertEqual(changes, 1)
        XCTAssertTrue(AppSettings(defaults: defaults).showsInvisibles)
    }

    func testADocumentShowsInvisiblesWhenTheSettingsDo() {
        let settings = AppSettings(defaults: defaults)
        let view = TestHelpers.isolatedDocumentView()

        settings.showsInvisibles = true
        view.apply(settings)
        let shown = view.viewport.showsInvisibles
        settings.showsInvisibles = false
        view.apply(settings)

        XCTAssertTrue(shown)
        XCTAssertFalse(view.viewport.showsInvisibles)
    }

    func testTheInvisiblesItemIsCheckedWhileTheyAreShown() {
        let delegate = AppDelegate()
        let item = NSMenuItem(title: "Invisibles", action: #selector(AppDelegate.toggleInvisibles),
                              keyEquivalent: "")

        let enabled = delegate.validateMenuItem(item)

        XCTAssertTrue(enabled)
        XCTAssertEqual(item.state, delegate.settings.showsInvisibles ? .on : .off)
    }

    func testRemoteImagesFollowTheSetting() {
        let markdown = Array("![badge](https://example.com/badge.svg)".utf8)

        let allowing = MarkdownRenderer.page(from: markdown, loadsRemoteImages: true)
        let blocking = MarkdownRenderer.page(from: markdown, loadsRemoteImages: false)

        XCTAssertTrue(allowing.contains("img-src file: data: https:"), allowing)
        XCTAssertTrue(blocking.contains("img-src file: data:;"), blocking)
        XCTAssertFalse(blocking.contains("https:;"), blocking)
    }
}
