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
    static let jsonIndentationKey = "BigEditJSONIndentation"
    static let jsonLineWidthKey = "BigEditJSONLineWidth"
    static let jsonSpacesAfterSeparatorsKey = "BigEditJSONSpacesAfterSeparators"
    static let xmlIndentationKey = "BigEditXMLIndentation"
    static let xmlLineWidthKey = "BigEditXMLLineWidth"

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

    @Published var jsonIndentation: FormattingOptions.Indentation {
        didSet {
            defaults.set(jsonIndentation.rawValue, forKey: AppSettings.jsonIndentationKey)
            onChange?()
        }
    }

    /// The width a JSON container is fitted within to stay on one line.
    @Published var jsonLineWidth: Int {
        didSet {
            let clamped = AppSettings.clampedLineWidth(jsonLineWidth)
            if clamped != jsonLineWidth {
                jsonLineWidth = clamped
            } else {
                defaults.set(jsonLineWidth, forKey: AppSettings.jsonLineWidthKey)
                onChange?()
            }
        }
    }

    @Published var jsonSpacesAfterSeparators: Bool {
        didSet {
            defaults.set(jsonSpacesAfterSeparators, forKey: AppSettings.jsonSpacesAfterSeparatorsKey)
            onChange?()
        }
    }

    @Published var xmlIndentation: FormattingOptions.Indentation {
        didSet {
            defaults.set(xmlIndentation.rawValue, forKey: AppSettings.xmlIndentationKey)
            onChange?()
        }
    }

    /// The width a start tag is fitted within before its attributes wrap.
    @Published var xmlLineWidth: Int {
        didSet {
            let clamped = AppSettings.clampedLineWidth(xmlLineWidth)
            if clamped != xmlLineWidth {
                xmlLineWidth = clamped
            } else {
                defaults.set(xmlLineWidth, forKey: AppSettings.xmlLineWidthKey)
                onChange?()
            }
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
        jsonIndentation = AppSettings.indentation(in: defaults, forKey: AppSettings.jsonIndentationKey)
        jsonLineWidth = AppSettings.lineWidth(in: defaults, forKey: AppSettings.jsonLineWidthKey)
        jsonSpacesAfterSeparators = defaults.object(forKey: AppSettings.jsonSpacesAfterSeparatorsKey) as? Bool ?? true
        xmlIndentation = AppSettings.indentation(in: defaults, forKey: AppSettings.xmlIndentationKey)
        xmlLineWidth = AppSettings.lineWidth(in: defaults, forKey: AppSettings.xmlLineWidthKey)
    }

    /// The editor font these settings describe.
    var editorFont: NSFont {
        EditorFont.font(family: fontFamily, size: fontSize)
    }

    /// How Pretty Print lays out JSON.
    var jsonFormattingOptions: FormattingOptions {
        var options = FormattingOptions()
        options.indentation = jsonIndentation
        options.lineWidth = jsonLineWidth
        options.spacesAfterSeparators = jsonSpacesAfterSeparators
        return options
    }

    /// How Pretty Print lays out XML.
    var xmlFormattingOptions: FormattingOptions {
        var options = FormattingOptions()
        options.indentation = xmlIndentation
        options.lineWidth = xmlLineWidth
        return options
    }

    private static func indentation(in defaults: UserDefaults, forKey key: String) -> FormattingOptions.Indentation {
        FormattingOptions.Indentation(rawValue: defaults.string(forKey: key) ?? "") ?? .twoSpaces
    }

    private static func lineWidth(in defaults: UserDefaults, forKey key: String) -> Int {
        clampedLineWidth(defaults.object(forKey: key) as? Int ?? FormattingOptions.defaultLineWidth)
    }

    private static func clampedLineWidth(_ width: Int) -> Int {
        min(max(width, FormattingOptions.lineWidthRange.lowerBound), FormattingOptions.lineWidthRange.upperBound)
    }
}
