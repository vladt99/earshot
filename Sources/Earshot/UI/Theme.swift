import AppKit
import ImageIO
import SwiftUI

/// Window background: the desktop wallpaper (or a picture chosen in Settings → Appearance), so the glass
/// panels have something to refract. On a flat colour Liquid Glass just looks grey.
struct Backdrop: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var scheme
    private let model = BackdropModel.shared

    var body: some View {
        ZStack {
            if let image = model.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.teal, .indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Rectangle().fill(scheme == .dark ? Color.black.opacity(0.18 + model.dim) : Color.white.opacity(model.dim))
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: state.backgroundVersion) { model.load(version: state.backgroundVersion) }
    }
}

/// The decoded background (shared by every window) and the dim amount. `AppState.backgroundVersion` changes
/// only when the picture does; dragging the Dim slider touches `dim` alone.
@MainActor
@Observable
final class BackdropModel {
    static let shared = BackdropModel()

    private(set) var image: NSImage?
    var dim = Settings.backgroundDim {
        didSet { Settings.backgroundDim = dim }
    }
    @ObservationIgnored private var version: Int?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Decodes off the main thread; the gradient shows until the first picture is ready.
    func load(version: Int) {
        guard self.version != version else { return }
        self.version = version
        let url = Settings.backgroundImage.map(URL.init(fileURLWithPath:))
            ?? NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        loading?.cancel()
        loading = Task {
            let cg = await Task.detached(priority: .utility) { url.flatMap(Self.thumbnail) }.value
            guard !Task.isCancelled else { return }
            image = cg.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    /// Wallpapers are often 6K; one downscaled copy is plenty for a window.
    nonisolated private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Cards

/// A floating Liquid Glass panel. `interactive` for panels you click, `tint` for ones that need attention.
struct Card: ViewModifier {
    var padding: CGFloat = 12
    var interactive = false
    var tint: Color?

    static let radius: CGFloat = 18

    func body(content: Content) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.22)) }
        if interactive { glass = glass.interactive() }
        return content
            .padding(padding)
            .containerShape(.rect(cornerRadius: Card.radius, style: .continuous))
            .glassEffect(glass, in: .rect(cornerRadius: Card.radius, style: .continuous))
    }
}

/// A field or well inside a card; its corners follow the card's.
struct Inset: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(.fill.quinary, in: ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true))
    }
}

extension View {
    func card(padding: CGFloat = 12, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(Card(padding: padding, interactive: interactive, tint: tint))
    }

    func inset() -> some View { modifier(Inset()) }

    /// Glass panel without padding, for large containers (sidebar, transcript, inspector).
    func panel(_ radius: CGFloat = 22) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
    }

    /// Glass shape with a given corner radius, for small controls and sheets.
    func glassCard(_ radius: CGFloat = Card.radius, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint),
                    in: .rect(cornerRadius: radius, style: .continuous))
    }

    func glassCapsule(tint: Color? = nil) -> some View {
        glassEffect(Glass.regular.tint(tint).interactive(), in: Capsule())
    }
}

/// Small title in the corner of a card.
struct CardHeader<Trailing: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            trailing
        }
        .frame(minHeight: 18)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, icon: String) {
        self.init(title: title, icon: icon) { EmptyView() }
    }
}

/// Heading between groups of cards.
struct SectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.top, 10)
        .padding(.leading, 4)
    }
}

/// The big figure in a stat card.
struct BigNumber: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .contentTransition(.numericText())
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
            .foregroundStyle(color)
    }
}

struct PulseDot: View {
    let color: Color
    let pulsing: Bool
    var size: CGFloat = 8

    @State private var expanded = false

    /// One repeating Core Animation-driven scale/fade instead of a per-frame redraw.
    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size, height: size)
                    .scaleEffect(expanded ? 2 : 1)
                    .opacity(expanded ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: expanded)
                    .onAppear { expanded = true }
                    .onDisappear { expanded = false }
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .accessibilityHidden(true)
    }
}

struct LevelBar: View {
    let value: Double
    var height: CGFloat = 6
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule().fill(color).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.5), value: value)
    }
}

/// Large centred empty state.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let action { Button(action.title, action: action.run).buttonStyle(.glass) }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// Settings sidebar group heading.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Fmt {
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    static func hours(_ s: Double) -> String {
        s >= 3600 ? String(format: "%.1f h", s / 3600) : "\(Int(s / 60)) min"
    }

    static func dayHeading(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .complete, time: .omitted)
    }
}
