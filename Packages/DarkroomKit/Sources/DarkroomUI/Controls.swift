import AppKit
import SwiftUI

/// The family's design language. Neutral greys only (equal R=G=B), so the interface never tints how
/// the photograph is perceived.
public enum Theme {
    public static let canvas = Color(white: 0.105)
    public static let panel = Color(white: 0.135)
    public static let hairline = Color(white: 0.21)
    public static let track = Color(white: 0.27)
    public static let text = Color(white: 0.90)
    public static let secondary = Color(white: 0.56)
    public static let tertiary = Color(white: 0.38)
    public static let accent = Color(white: 0.96)

    public static let label = Font.system(size: 11, weight: .medium)
    public static let value = Font.system(size: 11, weight: .regular).monospacedDigit()
    public static let section = Font.system(size: 10, weight: .semibold)

    /// Standard inspector width and spacings.
    public static let inspectorWidth: CGFloat = 284
    public static let sectionSpacing: CGFloat = 16
}

/// A quiet, precise slider: label and value above a hairline track. Double-click resets.
/// `onEditingChanged(true)` fires when a drag starts, `(false)` when it ends (also after a reset), so the
/// owner can group a whole drag into one undo step and switch between interactive and exact rendering.
public struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double
    var format: (Double) -> String
    /// Maps value <-> slider position (0…1), for non-linear controls such as temperature.
    var toPosition: ((Double) -> Double)?
    var fromPosition: ((Double) -> Double)?
    /// Draw a tick at the default (for bipolar controls).
    var centreMark: Bool
    var gradient: [Color]?
    var onEditingChanged: (Bool) -> Void

    @State private var dragging = false
    /// Double-click detection: the drag gesture sees every press, so a second press soon after a click
    /// (and close to it) is a double-click — the value goes back to its default.
    @State private var lastClick: (time: Date, x: CGFloat)?
    @State private var resetting = false

    public init(title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double,
                format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
                toPosition: ((Double) -> Double)? = nil, fromPosition: ((Double) -> Double)? = nil,
                centreMark: Bool = false, gradient: [Color]? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.format = format
        self.toPosition = toPosition
        self.fromPosition = fromPosition
        self.centreMark = centreMark
        self.gradient = gradient
        self.onEditingChanged = onEditingChanged
    }

    private func position(_ v: Double) -> Double {
        if let toPosition { return toPosition(v) }
        return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func value(at p: Double) -> Double {
        let p = min(max(p, 0), 1)
        if let fromPosition { return fromPosition(p) }
        return range.lowerBound + p * (range.upperBound - range.lowerBound)
    }

    public var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).font(Theme.label).foregroundStyle(dragging ? Theme.text : Theme.secondary)
                Spacer()
                Text(format(value)).font(Theme.value).foregroundStyle(abs(value - defaultValue) < 1e-9 ? Theme.tertiary : Theme.text)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onEditingChanged(true)
                value = defaultValue
                onEditingChanged(false)
            }
            .help("Double-click to reset")
            GeometryReader { geo in
                let w = geo.size.width
                let x = CGFloat(min(max(position(value), 0), 1)) * w
                ZStack(alignment: .leading) {
                    Group {
                        if let gradient {
                            LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing).opacity(0.55)
                        } else {
                            Theme.track
                        }
                    }
                    .frame(height: gradient == nil ? 1 : 2)
                    .clipShape(Capsule())
                    if centreMark {
                        Rectangle().fill(Theme.tertiary).frame(width: 1, height: 7)
                            .offset(x: CGFloat(position(defaultValue)) * w - 0.5)
                    }
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: dragging ? 11 : 9, height: dragging ? 11 : 9)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .offset(x: x - (dragging ? 5.5 : 4.5))
                        .animation(.easeOut(duration: 0.12), value: dragging)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !dragging {
                                dragging = true
                                onEditingChanged(true)
                                if let c = lastClick, Date().timeIntervalSince(c.time) < NSEvent.doubleClickInterval,
                                   abs(c.x - g.startLocation.x) < 6 {
                                    resetting = true
                                    lastClick = nil
                                    value = defaultValue
                                }
                            }
                            guard !resetting else { return }
                            let v = value(at: Double(g.location.x / w))
                            if v != value { value = v }
                        }
                        .onEnded { g in
                            let click = abs(g.translation.width) < 3 && abs(g.translation.height) < 3
                            lastClick = click && !resetting ? (Date(), g.startLocation.x) : nil
                            resetting = false
                            dragging = false
                            onEditingChanged(false)
                        }
                )
            }
            .frame(height: 14)
        }
        .help("Double-click to reset")
    }
}

public struct SectionHeader: View {
    let title: String
    public init(title: String) { self.title = title }
    public var body: some View {
        Text(title.uppercased())
            .font(Theme.section)
            .tracking(1.2)
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Collapsible inspector section with an icon, an on/off switch and a reset button in its header.
public struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String?
    @Binding var isEnabled: Bool
    @Binding var isExpanded: Bool
    let isModified: Bool
    let onReset: (() -> Void)?
    let showsToggle: Bool
    let content: Content
    @State private var hover = false

    /// `onReset` nil: no reset button; `showsToggle` false: no on/off switch.
    public init(title: String, icon: String? = nil, isEnabled: Binding<Bool>, isExpanded: Binding<Bool>, isModified: Bool,
                onReset: (() -> Void)?, showsToggle: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsToggle = showsToggle
        self.title = title
        self.icon = icon
        self._isEnabled = isEnabled
        self._isExpanded = isExpanded
        self.isModified = isModified
        self.onReset = onReset
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 10)
                        if let icon {
                            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(isEnabled ? Theme.secondary : Theme.tertiary)
                                .frame(width: 18)
                        }
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isEnabled ? Theme.text : Theme.tertiary)
                        if isModified && isEnabled { Circle().fill(Theme.secondary).frame(width: 4, height: 4) }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let onReset {
                    Button(action: onReset) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isModified ? Theme.secondary : Theme.tertiary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(title.lowercased())")
                    .disabled(!isModified)
                    .opacity(hover || isModified ? 1 : 0.5)
                }
                if showsToggle {
                    PowerToggle(isOn: $isEnabled).help(isEnabled ? "Turn \(title.lowercased()) off" : "Turn \(title.lowercased()) on")
                }
            }
            .onHover { hover = $0 }
            if isExpanded {
                content
                    .opacity(isEnabled ? 1 : 0.4)
                    .transition(.opacity)
            }
        }
    }
}

/// Small round on/off switch used in section headers.
public struct PowerToggle: View {
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { self._isOn = isOn }
    public var body: some View {
        Button { isOn.toggle() } label: {
            Circle()
                .strokeBorder(isOn ? Theme.secondary : Theme.tertiary, lineWidth: 1.2)
                .background(Circle().fill(isOn ? Theme.secondary : .clear).padding(3.5))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
    }
}

/// Small borderless icon button used in toolbars.
public struct IconButton: View {
    let symbol: String
    let help: String
    var active: Bool
    let action: () -> Void
    @State private var hover = false

    public init(symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 30, height: 26)
                .foregroundStyle(active ? Color.black : (hover ? Theme.text : Theme.secondary))
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.accent : (hover ? Theme.hairline : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Segmented control in the house style.
public struct Segmented: View {
    let options: [String]
    @Binding var selection: Int

    public init(options: [String], selection: Binding<Int>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i])
                    .font(Theme.label)
                    .lineLimit(1)
                    .foregroundStyle(selection == i ? Color.black : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selection == i ? Theme.accent : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = i }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
    }
}

public struct PlainTextButton: View {
    let title: String
    var symbol: String?
    var prominent: Bool
    let action: () -> Void
    @State private var hover = false

    public init(title: String, symbol: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.prominent = prominent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).font(Theme.label)
            }
            .foregroundStyle(prominent ? Color.black : (hover ? Theme.text : Theme.secondary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: prominent ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? (hover ? Color.white : Theme.accent) : (hover ? Theme.hairline : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(prominent ? .clear : Theme.hairline))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A thin vertical separator for toolbars.
public struct ToolbarDivider: View {
    public init() {}
    public var body: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 6) }
}

/// Floating capsule label, e.g. "Before" or "100%".
public struct Chip: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(Theme.section).tracking(1).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Status capsule with a spinner, shown at the bottom of the canvas.
public struct StatusCapsule: View {
    let text: String
    var progress: Double?
    public init(_ text: String, progress: Double? = nil) { self.text = text; self.progress = progress }
    public var body: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 120).tint(Theme.accent)
            } else {
                ProgressView().controlSize(.small).tint(Theme.secondary)
            }
            Text(text).font(Theme.label).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Theme.panel.opacity(0.94)))
        .overlay(Capsule().stroke(Theme.hairline))
    }
}
