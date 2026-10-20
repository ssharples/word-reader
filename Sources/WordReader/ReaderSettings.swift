import SwiftUI

struct ReaderSettings: View {
    @AppStorage(Prefs.fontSize) private var fontSize = 72.0
    @AppStorage(Prefs.fontStyle) private var fontStyle = ReaderFont.serif.rawValue
    @AppStorage(Prefs.showFocusLetter) private var showFocusLetter = true
    @AppStorage(Prefs.naturalPauses) private var naturalPauses = true

    private let keys: [(String, String)] = [
        ("Space", "Play or pause"),
        ("← →", "One word back or forward"),
        ("⌥← ⌥→", "One sentence back or forward"),
        ("↑ ↓", "Faster or slower"),
        ("[ ]", "Previous or next chapter"),
        ("V", "Read aloud on or off"),
        ("⌘+ ⌘−", "Bigger or smaller text"),
        ("Esc", "Pause, then back to the library"),
    ]

    var body: some View {
        Form {
            Section("Text") {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $fontSize, in: Prefs.fontSizeRange)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Font", selection: $fontStyle) {
                    ForEach(ReaderFont.allCases) { font in
                        Text(font.label).tag(font.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Colour the focus letter", isOn: $showFocusLetter)
            }
            Section {
                Toggle("Pause at punctuation", isOn: $naturalPauses)
            } footer: {
                Text("Holds a word a little longer after a comma or full stop, and longer still at the end of a paragraph, the way you'd pause reading aloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Keys") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(keys, id: \.0) { key, meaning in
                        GridRow {
                            Text(key).monospaced().foregroundStyle(.secondary)
                            Text(meaning)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}
