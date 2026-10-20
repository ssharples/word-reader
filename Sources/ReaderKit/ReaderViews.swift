import ReaderCore
import SwiftUI

#if os(macOS)
private let stageMargin = 32.0
private let contextSize = 16.0
#else
private let stageMargin = 18.0
private let contextSize = 17.0
#endif

/// The current word, with its focus letter fixed at the centre between two guide lines.
public struct WordStage: View {
    let session: ReaderSession
    let fontSize: Double
    let font: ReaderFont
    let showFocusLetter: Bool

    public init(session: ReaderSession, fontSize: Double, font: ReaderFont, showFocusLetter: Bool) {
        self.session = session
        self.fontSize = fontSize
        self.font = font
        self.showFocusLetter = showFocusLetter
    }

    public var body: some View {
        let lineHeight = fontSize * 1.35
        GeometryReader { geometry in
            let width = max(min(geometry.size.width - stageMargin * 2, 960), 200)
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
        let measure = font.platformFont(size: fontSize)
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
public struct PausedContext: View {
    let session: ReaderSession
    let font: ReaderFont

    public init(session: ReaderSession, font: ReaderFont) {
        self.session = session
        self.font = font
    }

    public var body: some View {
        // The stack stays while playing, so a frame around this keeps its height and the word doesn't move.
        ZStack(alignment: .top) {
            if !session.isPlaying {
                let context = session.context(radius: 24)
                (Text(context.before)
                    + Text(context.before.isEmpty ? "" : " ")
                    + Text(context.word).foregroundStyle(Theme.focus).fontWeight(.semibold)
                    + Text(context.after.isEmpty ? "" : " ")
                    + Text(context.after))
                    .font(.system(size: contextSize, design: font.design))
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640)
                    .padding(.horizontal, stageMargin)
                    .transition(.opacity)
            }
        }
    }
}

/// A plain cover for books that don't come with one.
public struct PlaceholderCover: View {
    let title: String
    let author: String?
    let titleSize: Double

    public init(title: String, author: String?, titleSize: Double = 15) {
        self.title = title
        self.author = author
        self.titleSize = titleSize
    }

    private var hue: Double {
        let hash = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Double(hash % 360) / 360
    }

    public var body: some View {
        LinearGradient(
            colors: [Color(hue: hue, saturation: 0.42, brightness: 0.58), Color(hue: hue, saturation: 0.55, brightness: 0.34)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                Spacer(minLength: 0)
                if let author {
                    Text(author)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(titleSize * 0.9)
            .padding(.top, titleSize * 0.65)
            .foregroundStyle(.white.opacity(0.92))
        }
    }
}
