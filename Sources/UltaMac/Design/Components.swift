import SwiftUI
import UltaMacCore

// MARK: - Page scaffolding

/// Every screen: a header with a tinted icon, title, subtitle and trailing actions,
/// then scrolling or fixed content with consistent margins.
struct Page<Actions: View, Content: View>: View {
    let destination: Destination
    var subtitle: String? = nil
    var scrolls = true
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(destination: destination, subtitle: subtitle) { actions }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.s)
            if scrolls {
                ScrollView {
                    content
                        .padding(.top, Theme.Space.s)
                        .padding(.horizontal, Theme.Space.page)
                        .padding(.bottom, Theme.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                content
                    .padding(.top, Theme.Space.s)
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.bottom, Theme.Space.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension Page where Actions == EmptyView {
    init(destination: Destination, subtitle: String? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(destination: destination, subtitle: subtitle, scrolls: scrolls, actions: { EmptyView() }, content: content)
    }
}

struct PageHeader<Actions: View>: View {
    let destination: Destination
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            IconBadge(symbol: destination.symbol, tint: destination.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle ?? destination.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: Theme.Space.l)
            HStack(spacing: Theme.Space.s) { actions }
        }
    }
}

struct IconBadge: View {
    let symbol: String
    let tint: Theme.Tint
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.gradient(tint))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .shadow(color: tint.color.opacity(0.35), radius: size * 0.15, y: size * 0.06)
    }
}

// MARK: - Cards & metrics

struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    Text(title).font(.headline)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(padding: padding)
    }
}

/// A big number with a caption. Numbers animate between values.
struct Metric: View {
    let value: String
    let caption: String
    var tint: Color = .primary
    var size: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Ring: View {
    let fraction: Double
    var tint: Theme.Tint = .brand
    var lineWidth: CGFloat = 12
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, shown)))
                .stroke(AngularGradient(colors: tint.colors + [tint.colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { animate(Motion.gentle) { shown = fraction } }
        .onChange(of: fraction) { _, new in animate(Motion.standard) { shown = new } }
    }
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    var tint: Theme.Tint = .brand

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(min(v, top) / top)))
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                }
                .fill(LinearGradient(colors: [tint.color.opacity(0.28), tint.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Theme.gradient(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct SizeBar: View {
    let fraction: Double
    var tint: Theme.Tint = .brand

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(Theme.gradient(tint)).frame(width: max(3, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

/// Badge for items UltaMac can't remove; hover explains why and how to fix it yourself.
struct LockPill: View {
    let lock: RemovalLock
    var body: some View {
        Pill(text: lock.shortLabel, tint: .orange, symbol: "lock.fill").help(lock.reason)
    }
}

struct RiskPill: View {
    let risk: RiskLevel
    var body: some View {
        switch risk {
        case .safe: Pill(text: risk.title, tint: .green, symbol: "checkmark.shield")
        case .low: Pill(text: risk.title, tint: .blue, symbol: "info.circle")
        case .review: Pill(text: risk.title, tint: .orange, symbol: "eye")
        }
    }
}

/// Filter chip row.
struct ChipPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { value, label in
                let on = selection == value
                Button { animate(Motion.spring) { selection = value } } label: {
                    Text(label).font(.callout.weight(on ? .semibold : .regular))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(on ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                        .foregroundStyle(on ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - States

struct EmptyHero: View {
    let symbol: String
    let tint: Theme.Tint
    let title: String
    let message: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ZStack {
                Circle().fill(Theme.gradient(tint).opacity(0.14)).frame(width: 132, height: 132)
                Circle().fill(Theme.gradient(tint)).frame(width: 92, height: 92)
                    .shadow(color: tint.color.opacity(0.4), radius: 18, y: 8)
                Image(systemName: symbol).font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                Text(title).font(.title2.bold())
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            if let buttonTitle, let action {
                Button(action: action) { Text(buttonTitle).frame(minWidth: 140) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}

/// Progress for a running scan. Shows a determinate bar only when a real total is known.
struct ScanProgress: View {
    let title: String
    let detail: String
    var fraction: Double? = nil
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            if let fraction {
                ZStack {
                    Ring(fraction: fraction, tint: .brand, lineWidth: 10).frame(width: 110, height: 110)
                    Text("\(Int(fraction * 100))%").font(.title2.bold().monospacedDigit()).contentTransition(.numericText())
                }
            } else {
                ProgressView().controlSize(.large)
            }
            VStack(spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            }
            if let onStop { Button("Stop", action: onStop) }
            Label("If macOS asks for access to a folder, answer the prompt. The scan waits for your choice; “Don't Allow” just skips that folder.",
                  systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: 460).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom bar summarising a selection with the primary removal action.
struct SelectionBar: View {
    let count: Int
    let bytes: Int64
    var actionTitle = "Review & Remove…"
    var tint: Theme.Tint = .clean
    var secondary: AnyView? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ByteFormat.string(bytes)).font(.title3.bold().monospacedDigit()).contentTransition(.numericText())
                Text("\(count) item\(count == 1 ? "" : "s") selected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let secondary { secondary }
            Button(action: action) {
                Label(actionTitle, systemImage: "trash").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(count == 0)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .background(.bar, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

/// Clearly-labelled placeholder for features on the roadmap but not built yet.
struct PlannedFeatureView: View {
    let destination: Destination

    var body: some View {
        Page(destination: destination) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.s) {
                    Pill(text: "NOT YET AVAILABLE", tint: .orange, symbol: "hammer")
                    Text("Planned for \(destination.plannedPhase ?? "a later phase")").foregroundStyle(.secondary)
                }
                Card(title: "What this will do", symbol: "list.bullet") {
                    ForEach(destination.plannedScope, id: \.self) { line in
                        Label(line, systemImage: "circle.dotted").foregroundStyle(.secondary)
                    }
                }
                Text("This screen is a placeholder. It doesn't scan, change or write anything.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Helpers

func relativeHomePath(_ url: URL) -> String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds > 86_400 ? [.day, .hour] : [.hour, .minute]
    f.unitsStyle = .abbreviated
    return f.string(from: seconds) ?? "—"
}

func relativeDate(_ date: Date?) -> String {
    guard let date else { return "Never" }
    return date.formatted(.relative(presentation: .named))
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}
