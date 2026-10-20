import ReaderCore
import ReaderKit
import SwiftUI
import UIKit

/// The reading screen: one word at a time. Tap to play or pause; drag sideways to move.
///
/// Only the small views that show the current word read `session.index`, so the rest
/// of the screen doesn't redraw on every word.
struct ReaderScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let session: ReaderSession

    @AppStorage(Prefs.fontSize) private var fontSize = Prefs.defaultFontSize
    @AppStorage(Prefs.fontStyle) private var fontStyle = ReaderFont.serif.rawValue
    @AppStorage(Prefs.showFocusLetter) private var showFocusLetter = true
    @AppStorage(Prefs.readAloud) private var readAloud = false
    @AppStorage("readerHintsShown") private var hintsShown = 0

    @State private var showSettings = false
    @State private var scrub: (start: Int, origin: CGFloat, resume: Bool)?
    @State private var scrubTick = 0

    private var font: ReaderFont { ReaderFont(rawValue: fontStyle) ?? .serif }
    private var compactHeight: Bool { verticalSizeClass == .compact }
    private var showControls: Bool { !session.isPlaying || scrub != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
            stage
            // Hidden rather than removed while playing, so the word never moves.
            ReaderPanel(session: session, compact: compactHeight)
                .opacity(showControls ? 1 : 0)
                .offset(y: showControls ? 0 : 12)
                .allowsHitTesting(showControls)
        }
        .foregroundStyle(Theme.ink)
        .background(Theme.paper.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: model.notice)
        .overlay {
            if session.reachedEnd {
                FinishedCard(session: session) { model.closeBook() }
            }
        }
        .statusBarHidden(session.isPlaying)
        .persistentSystemOverlays(session.isPlaying ? .hidden : .automatic)
        .sensoryFeedback(.selection, trigger: scrubTick)
        .sheet(isPresented: $showSettings) {
            SettingsScreen(inReader: true)
                .presentationDetents([.medium, .large])
        }
        .alert("Can't read aloud", isPresented: voiceProblemShown) {
            Button("Open Settings") { showSettings = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.voiceProblem ?? "")
        }
        .onChange(of: session.isPlaying) { _, playing in
            // Keep the screen on while words are moving.
            UIApplication.shared.isIdleTimerDisabled = playing
            if playing, hintsShown < 3 { hintsShown += 1 }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.pause()
        }
    }

    private var voiceProblemShown: Binding<Bool> {
        Binding(get: { session.voiceProblem != nil }, set: { if !$0 { session.voiceProblem = nil } })
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                model.closeBook()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to Library")
            VStack(spacing: 1) {
                Text(session.book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let chapter = session.chapterTitle {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            Button {
                let on = !readAloud
                session.setReadAloud(on)
                // The first time, the key has to go in before the voice can start.
                if on, ReadAloud.apiKey == nil { showSettings = true }
            } label: {
                Image(systemName: readAloud ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(readAloud ? Theme.focus : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Read aloud")
            .accessibilityValue(readAloud ? "On" : "Off")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Reading settings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// The word, and the sentence around it while paused. Tapping or dragging anywhere here works.
    private var stage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            WordStage(session: session, fontSize: fontSize, font: font, showFocusLetter: showFocusLetter)
            PausedContext(session: session, font: font)
                .frame(height: compactHeight ? 64 : 150, alignment: .top)
                .padding(.top, compactHeight ? 10 : 24)
            Group {
                if session.narrator?.isLoading == true {
                    Label {
                        Text("Getting the voice ready…")
                    } icon: {
                        ProgressView().controlSize(.mini)
                    }
                } else {
                    Text(hintsShown < 3 ? "Tap to play or pause · Drag sideways to move" : "")
                        .opacity(showControls && scrub == nil ? 1 : 0)
                }
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(height: 20)
            .padding(.top, 8)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(tapOrScrub)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAction(named: session.isPlaying ? "Pause" : "Play") { session.togglePlayback() }
    }

    /// A tap plays or pauses. A sideways drag moves a word for every 12 points:
    /// left to go forward, right to go back. One gesture does both, so neither swallows the other.
    private var tapOrScrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let across = drag.translation.width
                if scrub == nil {
                    guard abs(across) > 14, abs(across) > abs(drag.translation.height) else { return }
                    scrub = (session.index, across, session.isPlaying)
                    session.pause()
                }
                guard let scrub else { return }
                let target = min(max(scrub.start - Int(((across - scrub.origin) / 12).rounded()), 0), session.text.count - 1)
                if target != session.index {
                    session.move(to: target)
                    scrubTick += 1
                }
            }
            .onEnded { drag in
                if let scrub {
                    if scrub.resume { session.play() }
                    self.scrub = nil
                } else if abs(drag.translation.width) < 10, abs(drag.translation.height) < 10 {
                    session.togglePlayback()
                }
            }
    }
}

/// Progress, chapters, playback and speed, shown while paused.
struct ReaderPanel: View {
    let session: ReaderSession
    let compact: Bool
    @AppStorage(Prefs.wordsPerMinute) private var wordsPerMinute = 300
    @AppStorage(Prefs.naturalPauses) private var naturalPauses = true

    var body: some View {
        VStack(spacing: compact ? 8 : 16) {
            ProgressRow(session: session, wordsPerMinute: wordsPerMinute, naturalPauses: naturalPauses)
            if compact {
                HStack(spacing: 16) {
                    ChapterRow(session: session)
                    transport
                    speed
                }
            } else {
                ChapterRow(session: session)
                transport
                speed
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, compact ? 12 : 18)
        .padding(.bottom, compact ? 8 : 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.guide, lineWidth: 0.5))
        .frame(maxWidth: compact ? 900 : 560)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            PanelButton("backward.fill", label: "Previous sentence") { session.previousSentence() }
            PanelButton("chevron.backward", label: "Previous word") { session.step(-1) }
            Button {
                session.togglePlayback()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 20 : 26, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: compact ? 48 : 64, height: compact ? 48 : 64)
                    .background(Theme.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            PanelButton("chevron.forward", label: "Next word") { session.step(1) }
            PanelButton("forward.fill", label: "Next sentence") { session.nextSentence() }
        }
    }

    private var speed: some View {
        HStack(spacing: 10) {
            Image(systemName: "tortoise.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Slider(value: speedValue, in: Double(Prefs.speedRange.lowerBound)...Double(Prefs.speedRange.upperBound))
                .accessibilityLabel("Reading speed")
                .accessibilityValue("\(wordsPerMinute) words a minute")
            Image(systemName: "hare.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("\(wordsPerMinute) wpm")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
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
            .accessibilityLabel("Place in book")
            .accessibilityValue(Text(session.fraction, format: .percent.precision(.fractionLength(0))))
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

struct ChapterRow: View {
    let session: ReaderSession

    var body: some View {
        HStack(spacing: 4) {
            PanelButton("backward.end.fill", label: "Previous chapter") { session.previousChapter() }
            Menu {
                Picker("Chapter", selection: chapter) {
                    ForEach(Array(session.text.chapters.enumerated()), id: \.offset) { number, item in
                        Text(String(repeating: "    ", count: min(item.level, 4)) + item.title)
                            .tag(number)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(session.chapterTitle ?? "Contents")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .disabled(session.text.chapters.isEmpty)
            .accessibilityLabel("Chapter")
            .accessibilityValue(session.chapterTitle ?? "None")
            PanelButton("forward.end.fill", label: "Next chapter") { session.nextChapter() }
        }
        .foregroundStyle(Theme.ink)
    }

    private var chapter: Binding<Int> {
        Binding(get: { session.chapterIndex ?? -1 }, set: { session.jump(toChapter: $0) })
    }
}

struct PanelButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
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
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Read Again") { session.move(to: session.text.startIndex) }
                    .buttonStyle(.bordered)
                Button("Library", action: close)
                    .prominentButton()
            }
            .padding(.top, 8)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding(24)
    }
}
