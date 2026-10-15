import Sparkle

/// Sparkle's automatic-check preference, as the Settings window shows it.
/// Sparkle keeps the value itself, in user defaults.
final class UpdateSettings: ObservableObject {

    private let updater: SPUUpdater

    @Published var checksAutomatically: Bool {
        didSet {
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        checksAutomatically = updater.automaticallyChecksForUpdates
    }
}
