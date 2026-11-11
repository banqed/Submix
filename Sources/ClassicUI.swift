import SwiftUI
import AppKit

// MARK: - Classic 1-bit look

let ink = Color.black
let paper = Color.white

extension Font {
    /// ChicagoFLF is bundled in Resources (public domain, see Fonts/README.ChicagoFLF).
    static func chicago(_ size: CGFloat = 12) -> Font { .custom("ChicagoFLF", size: size) }
    static func geneva(_ size: CGFloat = 12) -> Font { .custom("Geneva", size: size) }
    static func monaco(_ size: CGFloat = 10) -> Font { .custom("Monaco", size: size) }
}

/// A Chicago label.
struct L: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.chicago()) }
}

struct ClassicButtonStyle: ButtonStyle {
    var isDefault = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.chicago())
            .padding(.horizontal, 10)
            .frame(minWidth: 50, minHeight: 20)
            .foregroundStyle(pressed ? paper : ink)
            .background(RoundedRectangle(cornerRadius: 6).fill(pressed ? ink : paper))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink, lineWidth: 1))
            .padding(isDefault ? 4 : 0)
            .overlay {
                if isDefault { RoundedRectangle(cornerRadius: 9).strokeBorder(ink, lineWidth: 3) }
            }
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

/// Small square icon button (reorder / delete arrows).
struct BoxButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 7, weight: .bold))
            .frame(width: 15, height: 15)
            .foregroundStyle(pressed ? paper : ink)
            .background(Rectangle().fill(pressed ? ink : paper))
            .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct ClassicRadio<T: Hashable>: View {
    let label: String
    let value: T
    @Binding var selection: T

    var body: some View {
        Button { selection = value } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().fill(paper)
                    Circle().strokeBorder(ink, lineWidth: 1)
                    if selection == value { Circle().fill(ink).padding(3) }
                }
                .frame(width: 12, height: 12)
                Text(label).font(.chicago())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ClassicCheckbox: View {
    var label: String = ""
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Rectangle().fill(paper)
                    Rectangle().strokeBorder(ink, lineWidth: 1)
                    if isOn {
                        Path { p in
                            p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 12, y: 12))
                            p.move(to: .init(x: 12, y: 0)); p.addLine(to: .init(x: 0, y: 12))
                        }
                        .stroke(ink, lineWidth: 1)
                    }
                }
                .frame(width: 12, height: 12)
                if !label.isEmpty { Text(label).font(.chicago()) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ClassicField<F: ParseableFormatStyle>: View where F.FormatOutput == String {
    @Binding var value: F.FormatInput
    let format: F
    var width: CGFloat = 70

    var body: some View {
        TextField("", value: $value, format: format)
            .classicFieldStyle(width: width)
    }
}

struct ClassicTextField: View {
    @Binding var text: String
    var width: CGFloat = 200

    var body: some View {
        TextField("", text: $text).classicFieldStyle(width: width)
    }
}

extension View {
    func classicFieldStyle(width: CGFloat) -> some View {
        self.textFieldStyle(.plain)
            .font(.geneva())
            .foregroundStyle(ink)
            .tint(ink)
            .focusEffectDisabled()
            .padding(.horizontal, 3)
            .frame(width: width, height: 18)
            .background(paper)
            .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
    }
}

/// Popup menu drawn as a box with a drop shadow and a down arrow.
struct ClassicPopup<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button(title(o)) { selection = o }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(selection)).font(.chicago())
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(paper)
            .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
            .background(Rectangle().fill(ink).offset(x: 1, y: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct ClassicGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.top, 13)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(title).font(.chicago()).foregroundStyle(ink)
                    .padding(.horizontal, 3)
                    .background(paper)
                    .offset(x: 8, y: -8)
            }
    }
}

/// Caution box, like an alert's body.
struct Banner: View {
    let text: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 16))
            Text(text).font(.geneva())
            Spacer()
            Button("Grant…", action: action).buttonStyle(ClassicButtonStyle())
        }
        .padding(7)
        .overlay(Rectangle().strokeBorder(ink, lineWidth: 2))
    }
}

// MARK: - Window chrome

/// Lets the striped title bar drag a borderless window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TitleBar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            WindowDragArea()
            Canvas { ctx, size in
                for i in 0..<6 {
                    let y = CGFloat(4 + i * 2)
                    ctx.fill(Path(CGRect(x: 1, y: y, width: size.width - 2, height: 1)), with: .color(ink))
                }
            }
            .allowsHitTesting(false)
            Text(title).font(.chicago()).foregroundStyle(ink)
                .padding(.horizontal, 8)
                .background(paper)
                .allowsHitTesting(false)
            HStack {
                Button(action: onClose) {
                    Rectangle().strokeBorder(ink, lineWidth: 1).background(paper)
                        .frame(width: 11, height: 11)
                }
                .buttonStyle(CloseBoxStyle())
                .padding(.horizontal, 2)
                .background(paper)
                .padding(.leading, 7)
                Spacer()
            }
        }
        .frame(height: 19)
        .overlay(alignment: .bottom) { Rectangle().fill(ink).frame(height: 1) }
    }
}

struct CloseBoxStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.overlay {
            if configuration.isPressed {
                // The little starburst a pressed close box shows.
                Path { p in
                    let c = CGPoint(x: 5.5, y: 5.5)
                    for a in stride(from: 0.0, to: .pi * 2, by: .pi / 4) {
                        p.move(to: CGPoint(x: c.x + cos(a) * 1.5, y: c.y + sin(a) * 1.5))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * 4.5, y: c.y + sin(a) * 4.5))
                    }
                }
                .stroke(ink, lineWidth: 1)
            }
        }
    }
}

/// Classic window frame: title bar, 1px border and 1px drop shadow.
struct ClassicWindowFrame<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: title) { NSApp.terminate(nil) }
            content.foregroundStyle(ink)
        }
        .background(paper)
        .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
        .background(Rectangle().fill(ink).offset(x: 1, y: 1))
        .padding([.trailing, .bottom], 1)
        .environment(\.colorScheme, .light)
    }
}

/// Borderless windows refuse key status by default, which would block typing in the fields.
final class ClassicWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
