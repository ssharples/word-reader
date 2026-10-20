import AppKit
import ReaderCore
import SwiftUI

/// The reading screen: one word at a time, with controls that fade away while it plays.
///
/// Only the small views that show the current word read `session.index`, so the rest
/// of the screen doesn't redraw on every word.
struct ReaderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    let session: ReaderSession

    @AppStorage(Prefs.fontSize) private var fontSize = 72.0
    @AppStorage(Prefs.fontStyle) private var fontStyle = ReaderFont.serif.rawValue
    @AppStorage(Prefs.showFocusLetter) private var showFocusLetter = true

    @State private var controlsVisible = true
    @State private var hoveringControls = false
    @State private var hideTask: Task<Void, Never>?
    @State private var keyMonitor: Any?

    private var font: ReaderFont { ReaderFont(rawValue: fontStyle) ?? .serif }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            WordStage(session: session, fontSize: fontSize, font: font, showFocusLetter: showFocusLetter)
            PausedContext(session: session, font: font)
                .frame(height: 150, alignment: .top)
                .padding(.top, 28)
            Spacer(minLength: 24)
            ReaderControls(session: session, hovering: $hoveringControls)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Theme.ink)
        .background(Theme.paper.ignoresSafeArea())
        .overlay {
            if session.reachedEnd {
                FinishedCard(session: session) { app.closeBook() }
            }
        }
        .navigationTitle(session.book.title)
        .navigationSubtitle(session.chapterTitle ?? "")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.closeBook()
                } label: {
                    Label("Library", systemImage: "chevron.backward")
                }
                .help("Back to Library (Esc)")
            }
        }
        .onContinuousHover { _ in showControls() }
        .onChange(of: session.isPlaying) { showControls() }
        .onAppear(perform: installKeys)
        .onDisappear {
            removeKeys()
            hideTask?.cancel()
            session.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // You can't read words you aren't looking at.
            session.pause()
        }
        .alert("Can't read aloud", isPresented: voiceProblemShown) {
            Button("Open Settings") { openSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.voiceProblem ?? "")
        }
    }

    private var voiceProblemShown: Binding<Bool> {
        @Bindable var session = session
        return Binding(get: { session.voiceProblem != nil }, set: { if !$0 { session.voiceProblem = nil } })
    }

    // MARK: Fading controls

    private func showControls() {
        hideTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
        guard session.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, session.isPlaying, !hoveringControls else { return }
            withAnimation(.easeInOut(duration: 0.6)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: Keys

    private struct KeyStroke: Sendable {
        let code: UInt16
        let characters: String
        let modifiers: NSEvent.ModifierFlags
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let stroke = KeyStroke(
                code: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            let handled = MainActor.assumeIsolated { handle(stroke) }
            return handled ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @MainActor
    private func handle(_ key: KeyStroke) -> Bool {
        if key.modifiers.contains(.command) {
            switch key.characters {
            case "=", "+": changeFontSize(by: 8)
            case "-": changeFontSize(by: -8)
            default: return false
            }
            return true
        }
        if key.modifiers.contains(.control) { return false }
        let option = key.modifiers.contains(.option)
        switch key.code {
        case 49: session.togglePlayback()                                  // space
        case 123: option ? session.previousSentence() : session.step(-1)   // ←
        case 124: option ? session.nextSentence() : session.step(1)        // →
        case 126: changeSpeed(by: Prefs.speedStep)                         // ↑
        case 125: changeSpeed(by: -Prefs.speedStep)                        // ↓
        case 53: session.isPlaying ? session.pause() : app.closeBook()     // esc
        default:
            switch key.characters {
            case "[": session.previousChapter()
            case "]": session.nextChapter()
            case "v", "V": session.setReadAloud(!UserDefaults.standard.bool(forKey: Prefs.readAloud))
            default: return false
            }
        }
        showControls()
        return true
    }

    private func changeSpeed(by delta: Int) {
        let defaults = UserDefaults.standard
        let speed = defaults.integer(forKey: Prefs.wordsPerMinute) + delta
        defaults.set(min(max(speed, Prefs.speedRange.lowerBound), Prefs.speedRange.upperBound), forKey: Prefs.wordsPerMinute)
    }

    private func changeFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, Prefs.fontSizeRange.lowerBound), Prefs.fontSizeRange.upperBound)
    }
}

/// The current word, with its focus letter fixed at the centre between two guide lines.
struct WordStage: View {
    let session: ReaderSession
    let fontSize: Double
    let font: ReaderFont
    let showFocusLetter: Bool

    var body: some View {
        let lineHeight = fontSize * 1.35
        GeometryReader { geometry in
            let width = max(min(geometry.size.width - 64, 960), 200)
            let parts = WordTiming.focusSplit(session.word)
            let size = fittedSize(parts, halfWidth: width / 2)
            VStack(spacing: fontSize * 0.2) {
                Guide(tickBelow: true)
                HStack(spacing: 0) {
                    Text(parts.before)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(parts.focus)
                        .foregroundStyle(showFocusLetter ? Theme.focus : Theme.ink)
                    Text(parts.after)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: size, design: font.design))
                .lineLimit(1)
                .frame(height: lineHeight)
                Guide(tickBelow: false)
            }
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: lineHeight + fontSize * 0.4 + 24)
        .accessibilityElement()
        .accessibilityLabel(session.word)
    }

    /// Shrinks long words so both halves fit either side of the focus letter.
    private func fittedSize(_ parts: (before: String, focus: String, after: String), halfWidth: Double) -> Double {
        let measure = font.nsFont(size: fontSize)
        func width(_ text: String) -> Double {
            (text as NSString).size(withAttributes: [.font: measure]).width
        }
        let needed = max(width(parts.before), width(parts.after)) + width(parts.focus) / 2
        guard needed > halfWidth - 8 else { return fontSize }
        return max(16, fontSize * (halfWidth - 8) / needed)
    }
}

/// A hairline with a small tick at the centre, pointing at the focus letter.
struct Guide: View {
    let tickBelow: Bool

    var body: some View {
        ZStack(alignment: tickBelow ? .top : .bottom) {
            Rectangle().fill(Theme.guide).frame(height: 1)
            Rectangle().fill(Theme.guide).frame(width: 2, height: 12)
        }
        .frame(height: 12)
    }
}

/// While paused, the words around the current one, so you can find your place.
struct PausedContext: View {
    let session: ReaderSession
    let font: ReaderFont

    var body: some View {
        if !session.isPlaying {
            let context = session.context(radius: 24)
            (Text(context.before)
                + Text(context.before.isEmpty ? "" : " ")
                + Text(context.word).foregroundStyle(Theme.focus).fontWeight(.semibold)
                + Text(context.after.isEmpty ? "" : " ")
                + Text(context.after))
                .font(.system(size: 16, design: font.design))
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
                .padding(.horizontal, 32)
                .transition(.opacity)
        }
    }
}

struct ReaderControls: View {
    let session: ReaderSession
    @Binding var hovering: Bool
    @AppStorage(Prefs.wordsPerMinute) private var wordsPerMinute = 300
    @AppStorage(Prefs.naturalPauses) private var naturalPauses = true
    @AppStorage(Prefs.readAloud) private var readAloud = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressRow(session: session, wordsPerMinute: wordsPerMinute, naturalPauses: naturalPauses)
            HStack(spacing: 0) {
                ChapterControls(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)
                transport
                speed
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.guide, lineWidth: 0.5))
        .frame(maxWidth: 1000)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .onHover { hovering = $0 }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            IconButton("backward.fill", help: "Previous sentence (⌥←)") { session.previousSentence() }
            IconButton("chevron.backward", help: "Previous word (←)") { session.step(-1) }
            Button {
                session.togglePlayback()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 48, height: 48)
                    .background(Theme.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .help(session.isPlaying ? "Pause (Space)" : "Play (Space)")
            IconButton("chevron.forward", help: "Next word (→)") { session.step(1) }
            IconButton("forward.fill", help: "Next sentence (⌥→)") { session.nextSentence() }
        }
    }

    private var speed: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: speedValue, in: Double(Prefs.speedRange.lowerBound)...Double(Prefs.speedRange.upperBound))
                .controlSize(.small)
                .frame(width: 130)
                .help("Reading speed (↑ and ↓)")
            Image(systemName: "hare.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(wordsPerMinute) wpm")
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .leading)
            Button {
                session.setReadAloud(!readAloud)
            } label: {
                Group {
                    if session.narrator?.isLoading == true {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: readAloud ? "speaker.wave.2.fill" : "speaker.slash")
                            .foregroundStyle(readAloud ? Theme.focus : .secondary)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(readAloud ? "Stop reading aloud (V)" : "Read aloud with ElevenLabs (V)")
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "textformat.size")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Text and reading settings")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                ReaderSettings()
            }
        }
    }

    /// A smooth slider that snaps to steps of 25 words a minute.
    private var speedValue: Binding<Double> {
        Binding(
            get: { Double(wordsPerMinute) },
            set: { wordsPerMinute = Int(($0 / Double(Prefs.speedStep)).rounded()) * Prefs.speedStep }
        )
    }
}

struct ProgressRow: View {
    let session: ReaderSession
    let wordsPerMinute: Int
    let naturalPauses: Bool
    @State private var resumeAfterDrag = false

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: position, in: 0...Double(max(session.text.count - 1, 1))) { dragging in
                if dragging {
                    resumeAfterDrag = session.isPlaying
                    session.pause()
                } else if resumeAfterDrag {
                    session.play()
                }
            }
            .controlSize(.mini)
            HStack {
                Text(session.fraction, format: .percent.precision(.fractionLength(0)))
                Spacer()
                Text(timeLeft)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var position: Binding<Double> {
        Binding(get: { Double(session.index) }, set: { session.move(to: Int($0.rounded())) })
    }

    private var timeLeft: String {
        let minutes = WordTiming.minutesLeft(
            words: session.text.count - session.index,
            wordsPerMinute: wordsPerMinute,
            naturalPauses: naturalPauses
        )
        if minutes < 1 { return "under a minute left" }
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) min left" }
        return "\(total / 60) h \(total % 60) min left"
    }
}

struct ChapterControls: View {
    let session: ReaderSession

    var body: some View {
        HStack(spacing: 2) {
            IconButton("backward.end.fill", help: "Previous chapter ([)") { session.previousChapter() }
            Menu {
                Picker("Chapter", selection: chapter) {
                    ForEach(Array(session.text.chapters.enumerated()), id: \.offset) { number, item in
                        Text(String(repeating: "    ", count: min(item.level, 4)) + item.title)
                            .tag(number)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(session.chapterTitle ?? "Contents")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 220)
            .fixedSize(horizontal: true, vertical: false)
            .help("Go to a chapter")
            IconButton("forward.end.fill", help: "Next chapter (])") { session.nextChapter() }
        }
    }

    private var chapter: Binding<Int> {
        Binding(get: { session.chapterIndex ?? -1 }, set: { session.jump(toChapter: $0) })
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct FinishedCard: View {
    let session: ReaderSession
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("The End")
                .font(.system(size: 34, design: .serif))
            Text("You've finished “\(session.book.title)”.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Read Again") { session.move(to: session.text.startIndex) }
                Button("Back to Library", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }
}
