import SwiftUI
import AppKit
import CoreAudio

// MARK: - Fader law

/// Fader and meter share one scale: linear in dB from -48 to +6, with the very bottom meaning off.
enum Taper {
    static let minDb = -48.0
    static let maxDb = 6.0
    static let off = -100.0
    private static let floor = 0.03      // fader travel below this is "off"

    static func db(at pos: Double) -> Double {
        pos <= floor ? off : minDb + (pos - floor) / (1 - floor) * (maxDb - minDb)
    }

    static func pos(of db: Double) -> Double {
        db <= minDb ? (db <= off ? 0 : floor) : min(1, floor + (db - minDb) / (maxDb - minDb) * (1 - floor))
    }

    static func linear(_ db: Double) -> Float { db <= off ? 0 : Float(pow(10, db / 20)) }

    static func pos(ofLevel level: Float) -> Double {
        level <= 0.0001 ? 0 : pos(of: 20 * log10(Double(level)))
    }

    static func label(_ db: Double) -> String {
        if db <= off { return "off" }
        let r = (db * 10).rounded() / 10
        return r == 0 ? "0.0 dB" : String(format: "%+.1f dB", r)
    }
}

// MARK: - Data

struct Channel: Codable, Identifiable, Equatable {
    var id: String                  // bundle ID
    var name: String
    var db = 0.0
    var muted = false
    var solo = false
    var slot = 0                    // engine slot, reassigned on load

    var short: String { name.replacingOccurrences(of: "Google ", with: "").replacingOccurrences(of: "Microsoft ", with: "") }
}

struct Candidate: Identifiable, Hashable {
    let id: String
    let name: String
    let playing: Bool
}

/// Meter levels live apart from the mixer so 30 updates a second only redraw the meters.
final class Meters: ObservableObject {
    @Published var levels: [Int: SIMD2<Float>] = [:]
}

// MARK: - Mixer

@MainActor
final class Mixer: ObservableObject {
    static let systemDefault = ""

    @Published var channels: [Channel] = [] { didSet { if channels != oldValue { saveChannels(); pushGains(); scheduleSync(0) } } }
    @Published var masterDb: Double { didSet { defaults.set(masterDb, forKey: "masterDb"); pushGains() } }
    @Published var masterMuted = false { didSet { pushGains() } }
    @Published var outputUID: String { didSet { defaults.set(outputUID, forKey: "outputUID"); rememberOutputName(); scheduleSync(0) } }
    @Published var bypass = false { didSet { scheduleSync(0) } }

    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var live: Set<String> = []
    @Published private(set) var permission = CapturePermission.status
    @Published private(set) var status = ""

    let meters = Meters()
    private let engine = MixEngine()
    private let defaults = UserDefaults.standard
    private var syncPending = false
    private var timers: [Timer] = []

    init() {
        masterDb = defaults.object(forKey: "masterDb") as? Double ?? 0
        outputUID = defaults.string(forKey: "outputUID") ?? Self.systemDefault
        if let data = defaults.data(forKey: "channels"),
           var saved = try? JSONDecoder().decode([Channel].self, from: data) {
            saved = Array(saved.prefix(MixEngine.maxSlots))
            for i in saved.indices { saved[i].slot = i }
            channels = saved
        }
        pushGains()
        listen()
        sync()
        if !channels.isEmpty { askIfUndecided() }
    }

    // MARK: Channels

    func add(_ c: Candidate) {
        guard !channels.contains(where: { $0.id == c.id }), channels.count < MixEngine.maxSlots else { return }
        let used = Set(channels.map(\.slot))
        let slot = (0..<MixEngine.maxSlots).first { !used.contains($0) } ?? 0
        channels.append(Channel(id: c.id, name: c.name, slot: slot))
        askIfUndecided()
    }

    func remove(_ id: String) { channels.removeAll { $0.id == id } }

    func binding(_ id: String) -> Binding<Channel> {
        Binding(
            get: { self.channels.first { $0.id == id } ?? Channel(id: id, name: "") },
            set: { new in if let i = self.channels.firstIndex(where: { $0.id == id }) { self.channels[i] = new } })
    }

    private func saveChannels() {
        if let data = try? JSONEncoder().encode(channels) { defaults.set(data, forKey: "channels") }
    }

    private func pushGains() {
        let anySolo = channels.contains { $0.solo }
        for c in channels {
            let audible = !c.muted && (!anySolo || c.solo)
            engine.setGain(slot: c.slot, audible ? Taper.linear(c.db) : 0)
        }
        engine.setGain(slot: MixEngine.masterSlot, masterMuted ? 0 : Taper.linear(masterDb))
    }

    // MARK: Output

    /// Popup entries: system default, every connected output, and the saved one if it's away.
    var outputOptions: [String] {
        var o = [Self.systemDefault] + devices.map(\.uid)
        if !o.contains(outputUID) { o.append(outputUID) }
        return o
    }

    func outputTitle(_ uid: String) -> String {
        if uid == Self.systemDefault { return "System Default" }
        if let d = devices.first(where: { $0.uid == uid }) { return d.name }
        return (defaults.string(forKey: "outputName") ?? "Saved output") + " (not connected)"
    }

    private func rememberOutputName() {
        if let d = devices.first(where: { $0.uid == outputUID }) { defaults.set(d.name, forKey: "outputName") }
    }

    // MARK: Permission

    /// The system prompt waits until there's something to mix, so it never appears out of nowhere.
    private func askIfUndecided() {
        if CapturePermission.status == .undetermined, !debugLogging { requestPermission() }
    }

    func requestPermission() {
        if CapturePermission.status == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        } else {
            CapturePermission.request { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
    }

    // MARK: Keeping the engine in step

    private func listen() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var a = propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(systemObject, &a, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleSync(0.2) }
            }
        }
        // Catches anything the listeners miss: apps that start or stop playing, permission changes.
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readMeters() }
        })
        for t in timers { RunLoop.main.add(t, forMode: .common) }
    }

    private func scheduleSync(_ delay: TimeInterval) {
        guard !syncPending else { return }
        syncPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.syncPending = false
                self?.sync()
            }
        }
    }

    func sync() {
        let perm = CapturePermission.status
        if perm != permission { permission = perm }

        let found = CA.outputDevices()
        if found != devices { devices = found; rememberOutputName() }

        let audio = CA.audioByApp()
        let mine = Set(channels.map(\.id))
        var list: [Candidate] = []
        var seen = mine
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            guard let id = app.bundleIdentifier, seen.insert(id).inserted else { continue }
            list.append(Candidate(id: id, name: app.localizedName ?? id, playing: audio[id]?.playing ?? false))
        }
        for (id, a) in audio where a.playing && seen.insert(id).inserted {      // menu bar and background players
            list.append(Candidate(id: id, name: a.name, playing: true))
        }
        list.sort { ($0.playing ? 0 : 1, $0.name.lowercased()) < ($1.playing ? 0 : 1, $1.name.lowercased()) }
        if list != candidates { candidates = list }

        let target = outputUID == Self.systemDefault ? CA.defaultOutputUID() : outputUID
        let connected = target.flatMap { t in found.first { $0.uid == t } }
        var desired: [Int: [AudioObjectID]] = [:]
        var names: [Int: String] = [:]
        for c in channels {
            desired[c.slot] = audio[c.id]?.objects ?? []
            names[c.slot] = c.name
        }
        engine.apply(desired: desired, names: names, outputUID: connected?.uid,
                     enabled: !bypass && perm == .granted)

        let liveSlots = engine.liveSlots
        let nowLive = Set(channels.filter { liveSlots.contains($0.slot) }.map(\.id))
        if nowLive != live { live = nowLive }

        let text: String
        if let e = engine.lastError { text = e }
        else if perm != .granted, !channels.isEmpty { text = "Needs permission to hear other apps." }
        else if bypass { text = "Bypassed. Apps play as normal." }
        else if channels.isEmpty { text = "Add an app to start mixing." }
        else if connected == nil { text = "Output not connected. Apps play as normal." }
        else if !engine.isRunning { text = "Waiting for an app to make sound." }
        else { text = "Mixing \(nowLive.count) app\(nowLive.count == 1 ? "" : "s") to \(connected!.name)." }
        if text != status { status = text }
    }

    private func readMeters() {
        var next: [Int: SIMD2<Float>] = [:]
        var active = false
        for slot in channels.map(\.slot) + [MixEngine.masterSlot] {
            let (l, r) = engine.takePeak(slot: slot)
            let old = meters.levels[slot] ?? .zero
            let v = SIMD2(max(l, old.x * 0.82), max(r, old.y * 0.82))
            if v.x > 0.0001 || v.y > 0.0001 { next[slot] = v; active = true }
        }
        if active || !meters.levels.isEmpty { meters.levels = next }
    }

    func shutdown() {
        timers.forEach { $0.invalidate() }
        engine.shutdown()
    }
}
