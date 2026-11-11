import SwiftUI
import AppKit

private let travel: CGFloat = 156      // fader travel and meter height, in points
private let knobHeight: CGFloat = 13

struct ContentView: View {
    @ObservedObject var m: Mixer

    var body: some View {
        ClassicWindowFrame("Submix") {
            VStack(alignment: .leading, spacing: 14) {
                if m.permission != .granted && !m.channels.isEmpty {
                    Banner(text: "Submix needs System Audio Recording permission to hear other apps.") {
                        m.requestPermission()
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    ForEach(m.channels) { c in
                        ChannelStrip(c: m.binding(c.id), live: m.live.contains(c.id), meters: m.meters) {
                            m.remove(c.id)
                        }
                    }
                    if m.channels.isEmpty {
                        Text("No apps yet.\nUse Add App to\nbring one in.")
                            .font(.geneva()).multilineTextAlignment(.center)
                            .frame(width: 150).frame(maxHeight: .infinity)
                            .overlay(Rectangle().strokeBorder(ink, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    }
                    Rectangle().fill(ink).frame(width: 1).padding(.horizontal, 3)
                    MasterStrip(m: m)
                }

                ClassicGroup("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ClassicPopup(options: m.outputOptions, title: m.outputTitle, selection: $m.outputUID)
                            Spacer(minLength: 0)
                            ClassicCheckbox(label: "Bypass", isOn: $m.bypass)
                        }
                        Text(m.status).font(.geneva(10)).lineLimit(1)
                    }
                }

                HStack {
                    AddAppMenu(m: m)
                    Spacer()
                }
            }
            .fixedSize()
            .padding(16)
        }
    }
}

// MARK: - Strips

struct ChannelStrip: View {
    @Binding var c: Channel
    let live: Bool
    let meters: Meters
    let remove: () -> Void

    var body: some View {
        StripBox(title: c.short, trailing: {
            Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(BoxButtonStyle())
        }) {
            DitheredIcon(bundleID: c.id)
            FaderRow(db: $c.db, slot: c.slot, meters: meters)
            Text(live ? Taper.label(c.db) : "silent").font(.geneva(10))
            VStack(alignment: .leading, spacing: 5) {
                ClassicCheckbox(label: "Mute", isOn: $c.muted)
                ClassicCheckbox(label: "Solo", isOn: $c.solo)
            }
        }
    }
}

struct MasterStrip: View {
    @ObservedObject var m: Mixer

    var body: some View {
        StripBox(title: "Master", trailing: { EmptyView() }) {
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 20))
                .frame(width: 32, height: 32)
            FaderRow(db: $m.masterDb, slot: MixEngine.masterSlot, meters: m.meters)
            Text(Taper.label(m.masterDb)).font(.geneva(10))
            VStack(alignment: .leading, spacing: 5) {
                ClassicCheckbox(label: "Mute", isOn: $m.masterMuted)
                ClassicCheckbox(label: "Solo", isOn: .constant(false)).hidden()
            }
        }
    }
}

/// A strip drawn as a small box with a header, like a mini window.
struct StripBox<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Text(title).font(.chicago()).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 5)
            .frame(height: 21)
            .overlay(alignment: .bottom) { Rectangle().fill(ink).frame(height: 1) }
            VStack(spacing: 7) { content }
                .padding(.vertical, 8)
        }
        .frame(width: 92)
        .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
    }
}

// MARK: - Fader and meter

struct FaderRow: View {
    @Binding var db: Double
    let slot: Int
    let meters: Meters

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            Scale().frame(width: 20, height: travel + knobHeight)
            Fader(db: $db)
            Meter(slot: slot, meters: meters)
        }
    }
}

/// dB marks beside the fader.
struct Scale: View {
    private let marks: [Double] = [6, 0, -6, -12, -24, -36, -48]

    var body: some View {
        Canvas { ctx, size in
            for d in marks {
                let y = knobHeight / 2 + (1 - Taper.pos(of: d)) * travel
                let unity = d == 0
                ctx.fill(Path(CGRect(x: size.width - (unity ? 5 : 3), y: y.rounded(), width: unity ? 5 : 3, height: 1)),
                         with: .color(ink))
                ctx.draw(Text("\(Int(abs(d)))").font(.geneva(9)).foregroundColor(ink),
                         at: CGPoint(x: size.width - 7, y: y), anchor: .trailing)
            }
        }
    }
}

struct Fader: View {
    @Binding var db: Double
    private let width: CGFloat = 26

    var body: some View {
        let y = knobHeight / 2 + (1 - Taper.pos(of: db)) * travel
        ZStack(alignment: .top) {
            Rectangle().fill(paper)
                .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
                .frame(width: 5, height: travel + knobHeight)
            // Knob: a white cap with a drop shadow and a centre line.
            Rectangle().fill(paper)
                .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
                .overlay(Rectangle().fill(ink).frame(height: 1).padding(.horizontal, 3))
                .background(Rectangle().fill(ink).offset(x: 1, y: 1))
                .frame(width: width - 4, height: knobHeight)
                .offset(y: (y - knobHeight / 2).rounded())
        }
        .frame(width: width, height: travel + knobHeight, alignment: .top)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let pos = 1 - (g.location.y - knobHeight / 2) / travel
            let v = Taper.db(at: min(1, max(0, pos)))
            db = abs(v) < 0.4 ? 0 : (v * 2).rounded() / 2      // half-dB steps, sticky at unity
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { db = 0 })
        .help("Drag to set level. Double-click for 0 dB.")
    }
}

/// Two segmented bars on the fader's scale. Anything above the 0 mark is clipping.
struct Meter: View {
    let slot: Int
    @ObservedObject var meters: Meters
    private let segment: CGFloat = 4       // 3 lit + 1 gap

    var body: some View {
        let level = meters.levels[slot] ?? .zero
        Canvas { ctx, size in
            let count = Int(travel / segment)
            for (i, v) in [level.x, level.y].enumerated() {
                let x = CGFloat(i) * 7
                ctx.stroke(Path(CGRect(x: x + 0.5, y: 0.5, width: 5, height: size.height - 1)), with: .color(ink), lineWidth: 1)
                let lit = Int((Taper.pos(ofLevel: v) * Double(count)).rounded(.down))
                guard lit > 0 else { continue }
                var p = Path()
                for s in 0..<min(lit, count) {
                    p.addRect(CGRect(x: x + 1, y: size.height - 1 - CGFloat(s + 1) * segment + 1, width: 4, height: segment - 1))
                }
                ctx.fill(p, with: .color(ink))
            }
        }
        .frame(width: 13, height: travel + 2)
    }
}

// MARK: - Add App

struct AddAppMenu: View {
    @ObservedObject var m: Mixer

    var body: some View {
        Menu {
            if m.candidates.isEmpty { Text("No other apps are running") }
            ForEach(m.candidates) { c in
                Button(c.playing ? "♪ \(c.name)" : c.name) { m.add(c) }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Add App").font(.chicago())
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(paper))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - 1-bit app icons

/// The app's icon, Atkinson-dithered down to a 32×32 black-and-white bitmap.
struct DitheredIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let image = IconCache.icon(for: bundleID) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
            } else {
                Rectangle().strokeBorder(ink, lineWidth: 1)
            }
        }
        .frame(width: 32, height: 32)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: CGImage] = [:]

    static func icon(for bundleID: String) -> CGImage? {
        if let hit = cache[bundleID] { return hit }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let source = app?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        guard let source, let image = dither(source) else { return nil }
        cache[bundleID] = image
        return image
    }

    private static func dither(_ icon: NSImage) -> CGImage? {
        let n = 32
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &rgba, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        var rect = CGRect(x: 0, y: 0, width: n, height: n)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: CGRect(x: -3, y: -3, width: n + 6, height: n + 6))   // trim the icon's built-in margin

        // Luminance of the solid pixels, stretched to full range so pale icons keep their detail.
        var gray = [Float](repeating: 1, count: n * n)
        var solid = [Bool](repeating: false, count: n * n)
        var lo: Float = 1, hi: Float = 0
        for i in 0..<(n * n) {
            let a = Float(rgba[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            solid[i] = true
            let l = (0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])) / 255 / a
            gray[i] = min(1, l)
            lo = min(lo, gray[i])
            hi = max(hi, gray[i])
        }
        let range = max(hi - lo, 0.05)
        for i in 0..<(n * n) where solid[i] {
            gray[i] = pow((gray[i] - lo) / range, 1.3)
        }
        // A black outline where the icon meets empty space, like a hand-drawn classic icon.
        for y in 0..<n {
            for x in 0..<n where solid[y * n + x] {
                let edge = x == 0 || y == 0 || x == n - 1 || y == n - 1
                    || !solid[y * n + x - 1] || !solid[y * n + x + 1] || !solid[(y - 1) * n + x] || !solid[(y + 1) * n + x]
                if edge { gray[y * n + x] = -1 }
            }
        }
        var bits = [UInt8](repeating: 255, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let old = gray[y * n + x]
                if old < 0 { bits[y * n + x] = 0; continue }       // outline
                if !solid[y * n + x] { continue }                   // empty space stays white
                let new: Float = old < 0.5 ? 0 : 1
                bits[y * n + x] = new == 0 ? 0 : 255
                let e = (old - new) / 8
                for (dx, dy) in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, xx < n, yy < n, gray[yy * n + xx] >= 0 { gray[yy * n + xx] += e }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bits) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
