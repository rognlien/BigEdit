import SwiftUI

/// The Formatting pane of the Settings window: how Edit ▸ Format ▸ Pretty
/// Print lays out JSON and XML. Labels are right-aligned beside their
/// controls, as in the panes of Xcode's and TextEdit's settings.
struct FormattingSettingsView: View {

    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            indentationPicker("JSON indentation:", selection: $settings.jsonIndentation)
            lineWidthField("JSON line width:", value: $settings.jsonLineWidth)
            Toggle("Space after “:” and “,” in one-line containers", isOn: $settings.jsonSpacesAfterSeparators)
            Text("An object or array that fits within the line width stays on one line. "
                 + "At 0, every one is broken onto several.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            indentationPicker("XML indentation:", selection: $settings.xmlIndentation)
            lineWidthField("XML line width:", value: $settings.xmlLineWidth)
            Text("A start tag wider than this puts each attribute after the first on its own line, "
                 + "aligned under the first. At 0, attributes stay on the tag’s line.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func indentationPicker(_ title: String,
                                   selection: Binding<FormattingOptions.Indentation>) -> some View {
        Picker(title, selection: selection) {
            ForEach(FormattingOptions.Indentation.allCases) { indentation in
                Text(indentation.title).tag(indentation)
            }
        }
        .fixedSize()
    }

    private func lineWidthField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                Stepper(title, value: value, in: FormattingOptions.lineWidthRange)
                    .labelsHidden()
                Text("columns")
            }
        }
    }
}
