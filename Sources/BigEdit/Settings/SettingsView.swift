import SwiftUI

/// The General pane of the Settings window, grouped like System Settings.
struct SettingsView: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateSettings

    private let fontFamilies = EditorFont.monospacedFamilies()

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }

            Section("Editor") {
                Picker("Font", selection: $settings.fontFamily) {
                    Text("System Monospaced").tag(String?.none)
                    Divider()
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(String?.some(family))
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                        Stepper("Size", value: $settings.fontSize,
                                in: ViewportView.minFontSize...ViewportView.maxFontSize, step: 1)
                            .labelsHidden()
                    }
                }
                Text("{ \"name\": \"BigEdit\", \"size\": 4564416 }")
                    .font(Font(settings.editorFont))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Load remote images", isOn: $settings.loadsRemoteImages)
            } header: {
                Text("Markdown")
            } footer: {
                Text("Loading a picture from the web tells its server that you opened the document.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
