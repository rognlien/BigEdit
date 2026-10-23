import AppKit
import SwiftUI
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

    func testFormattingDefaultsWhenNothingIsStored() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.jsonFormattingOptions, FormattingOptions())
        XCTAssertEqual(settings.xmlIndentation, .twoSpaces)
        XCTAssertEqual(settings.xmlLineWidth, 80)
        XCTAssertTrue(settings.jsonSpacesAfterSeparators)
    }

    func testFormattingChangesPersistAndAreReported() {
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }

        settings.jsonIndentation = .tab
        settings.jsonLineWidth = 0
        settings.jsonSpacesAfterSeparators = false
        settings.xmlIndentation = .fourSpaces
        settings.xmlLineWidth = 120

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(changes, 5)
        XCTAssertEqual(reloaded.jsonFormattingOptions.indentation, .tab)
        XCTAssertEqual(reloaded.jsonFormattingOptions.lineWidth, 0)
        XCTAssertFalse(reloaded.jsonFormattingOptions.spacesAfterSeparators)
        XCTAssertEqual(reloaded.xmlFormattingOptions.indentation, .fourSpaces)
        XCTAssertEqual(reloaded.xmlFormattingOptions.lineWidth, 120)
    }

    func testLineWidthsStayWithinTheirRange() {
        let settings = AppSettings(defaults: defaults)

        settings.jsonLineWidth = -5
        settings.xmlLineWidth = 10_000

        XCTAssertEqual(settings.jsonLineWidth, 0)
        XCTAssertEqual(settings.xmlLineWidth, FormattingOptions.lineWidthRange.upperBound)
        XCTAssertEqual(AppSettings(defaults: defaults).xmlLineWidth, FormattingOptions.lineWidthRange.upperBound)
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

    func testTheSettingsWindowSizesItselfToThePaneChosen() {
        let panes = SettingsTabViewController()
        panes.tabStyle = .toolbar
        for (title, height) in [("Small", 100.0), ("Tall", 300.0)] {
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
            controller.preferredContentSize = NSSize(width: 400, height: height)
            controller.title = title
            panes.addTabViewItem(NSTabViewItem(viewController: controller))
        }
        let window = NSWindow(contentViewController: panes)

        panes.selectedTabViewItemIndex = 1

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, 300, accuracy: 1)
    }

    func testTheFormattingPaneLaysOut() {
        let controller = NSHostingController(rootView: FormattingSettingsView(settings: AppSettings(defaults: defaults)))

        XCTAssertGreaterThan(controller.view.fittingSize.height, 150)
        XCTAssertEqual(controller.view.fittingSize.width, 520, accuracy: 1)
    }
}
