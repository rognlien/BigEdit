import AppKit

/// The preferences shown in the Settings window, kept in user defaults.
///
/// Every change is saved straight away and reported through `onChange`, so
/// the app applies it to the open documents while the window is still open.
final class AppSettings: ObservableObject {

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        /// The appearance to force on the app, or nil to follow the system.
        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    static let appearanceKey = "BigEditAppearance"
    static let fontFamilyKey = "BigEditFontFamily"
    static let fontSizeKey = "BigEditFontSize"
    static let loadsRemoteImagesKey = "BigEditLoadsRemoteImages"
    static let showsInvisiblesKey = "BigEditShowsInvisibles"

    /// Called after any setting changes.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: AppSettings.appearanceKey)
            onChange?()
        }
    }

    /// The editor's font family, or nil for the system monospaced font.
    @Published var fontFamily: String? {
        didSet {
            defaults.set(fontFamily, forKey: AppSettings.fontFamilyKey)
            onChange?()
        }
    }

    @Published var fontSize: CGFloat {
        didSet {
            defaults.set(Double(fontSize), forKey: AppSettings.fontSizeKey)
            onChange?()
        }
    }

    /// Whether rendered Markdown shows pictures from the web. Fetching one
    /// tells its server that the document was opened.
    @Published var loadsRemoteImages: Bool {
        didSet {
            defaults.set(loadsRemoteImages, forKey: AppSettings.loadsRemoteImagesKey)
            onChange?()
        }
    }

    /// Whether the editor marks spaces, line endings and other invisible
    /// characters, chosen with View ▸ Invisibles.
    @Published var showsInvisibles: Bool {
        didSet {
            defaults.set(showsInvisibles, forKey: AppSettings.showsInvisiblesKey)
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedAppearance = defaults.string(forKey: AppSettings.appearanceKey) ?? ""
        appearance = Appearance(rawValue: storedAppearance) ?? .system
        fontFamily = defaults.string(forKey: AppSettings.fontFamilyKey)
        let storedSize = defaults.double(forKey: AppSettings.fontSizeKey)
        fontSize = storedSize > 0 ? CGFloat(storedSize) : ViewportView.defaultFontSize
        loadsRemoteImages = defaults.object(forKey: AppSettings.loadsRemoteImagesKey) as? Bool ?? true
        showsInvisibles = defaults.bool(forKey: AppSettings.showsInvisiblesKey)
    }

    /// The editor font these settings describe.
    var editorFont: NSFont {
        EditorFont.font(family: fontFamily, size: fontSize)
    }
}
