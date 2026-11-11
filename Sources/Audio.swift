import AppKit
import CoreAudio
import AudioToolbox
import Accelerate

// MARK: - Debug log

let debugLogging = ProcessInfo.processInfo.environment["SUBMIX_DEBUG"] != nil
func dlog(_ s: @autoclosure () -> String) {
    if debugLogging { FileHandle.standardError.write((s() + "\n").data(using: .utf8)!) }
}

// MARK: - Core Audio property helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let aggregatePrefix = "submix-aggregate-"

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

enum CA {
    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var a = propertyAddress(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buf = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, buf) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buf, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var a = propertyAddress(selector)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? v : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = propertyAddress(selector)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }

    static func hasStreams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var a = propertyAddress(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr && size > 0
    }
}

// MARK: - Output devices

struct OutputDevice: Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

extension CA {
    static func outputDevices() -> [OutputDevice] {
        array(systemObject, kAudioHardwarePropertyDevices, of: AudioObjectID.self).compactMap { id in
            guard hasStreams(id, kAudioObjectPropertyScopeOutput),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(aggregatePrefix) else { return nil }
            return OutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func defaultOutputUID() -> String? {
        guard let id = value(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
              id != kAudioObjectUnknown else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }
}

// MARK: - Which app owns an audio process

/// Audio often comes from a helper (Discord's renderer, a browser's GPU process), so every
/// audio process is traced back to the app the user would recognise.
enum AppLookup {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    static func owner(of pid: pid_t) -> NSRunningApplication? {
        let own = NSRunningApplication(processIdentifier: pid)
        if let own, own.activationPolicy == .regular { return own }
        if let r = responsible?(pid), r > 1, r != pid,
           let app = NSRunningApplication(processIdentifier: r), app.bundleIdentifier != nil { return app }
        var p = parent(of: pid)
        var hops = 0
        while p > 1, hops < 8 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            p = parent(of: p)
            hops += 1
        }
        return own
    }
}

/// The audio processes belonging to one app.
struct AppAudio {
    var name: String
    var objects: [AudioObjectID]
    var playing: Bool
}

extension CA {
    /// Every process known to Core Audio, grouped by owning app's bundle ID.
    static func audioByApp() -> [String: AppAudio] {
        var out: [String: AppAudio] = [:]
        let me = getpid()
        for object in array(systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
            guard let pid = value(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid != me, pid > 0,
                  let app = AppLookup.owner(of: pid), let key = app.bundleIdentifier,
                  app.processIdentifier != me else { continue }
            let playing = (value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            var entry = out[key] ?? AppAudio(name: app.localizedName ?? key, objects: [], playing: false)
            entry.objects.append(object)
            entry.playing = entry.playing || playing
            out[key] = entry
        }
        for key in out.keys { out[key]!.objects.sort() }
        return out
    }
}

// MARK: - System Audio Recording permission

/// There is no public call to ask whether system audio capture is allowed, and a denied tap
/// just delivers silence. This uses the TCC framework directly and assumes "granted" if that
/// ever stops working, so the app still runs.
enum CapturePermission {
    enum Status { case granted, denied, undetermined }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var status: Status {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .granted }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt if the user hasn't decided yet.
    static func request(_ done: @escaping (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { done(true); return }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { ok in
            DispatchQueue.main.async { done(ok) }
        }
    }
}

// MARK: - Mix engine

/// What the realtime callback needs. Only raw pointers, so calling it never touches
/// reference counts or locks.
private struct RenderContext {
    let state: UnsafeMutablePointer<Float>
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let slots: UnsafeMutablePointer<Int32>
    let tapCount: Int
}

/// Sums one process tap per app into a chosen output device.
///
/// Each app gets a tap that mutes the app's normal output while it is being read. The taps
/// and the output device sit in one private aggregate device, so a single IO callback reads
/// every app and writes the mix on the output device's clock.
final class MixEngine {
    static let maxSlots = 32
    static let masterSlot = maxSlots
    private static let fields = 4          // target gain, current gain, peak L, peak R
    private static let maxFrames = 8192

    private struct Tap {
        var id: AudioObjectID
        var uid: String
        var objects: [AudioObjectID]
    }

    private let state: UnsafeMutablePointer<Float>
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var taps: [Int: Tap] = [:]
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var slotOrder: UnsafeMutablePointer<Int32>?
    private(set) var deviceUID: String?
    private(set) var lastError: String?

    var isRunning: Bool { procID != nil }
    var liveSlots: Set<Int> { isRunning ? Set(taps.keys) : [] }

    init() {
        let n = (Self.maxSlots + 1) * Self.fields
        state = .allocate(capacity: n)
        state.initialize(repeating: 0, count: n)
        left = .allocate(capacity: Self.maxFrames)
        right = .allocate(capacity: Self.maxFrames)
        left.initialize(repeating: 0, count: Self.maxFrames)
        right.initialize(repeating: 0, count: Self.maxFrames)
    }

    func setGain(slot: Int, _ linear: Float) { state[slot * Self.fields] = linear }

    /// Peak since the last call, as linear amplitude.
    func takePeak(slot: Int) -> (Float, Float) {
        let s = state + slot * Self.fields
        let p = (s[2], s[3])
        s[2] = 0
        s[3] = 0
        return p
    }

    /// Makes the running graph match what's wanted. Does nothing if it already does.
    /// - Parameter desired: slot → the app's audio process objects (sorted).
    func apply(desired: [Int: [AudioObjectID]], names: [Int: String], outputUID: String?, enabled: Bool) {
        let wanted = desired.filter { !$0.value.isEmpty }
        let shouldRun = enabled && outputUID != nil && !wanted.isEmpty
        let tapsMatch = Set(wanted.keys) == Set(taps.keys) && wanted.allSatisfy { taps[$0.key]?.objects == $0.value }
        if shouldRun, isRunning, tapsMatch, outputUID == deviceUID { return }
        if !shouldRun, !isRunning, taps.isEmpty { return }

        stopIO()
        for (slot, tap) in taps where !shouldRun || wanted[slot] != tap.objects {
            AudioHardwareDestroyProcessTap(tap.id)
            taps[slot] = nil
        }
        lastError = nil
        guard shouldRun, let outputUID else { return }

        for (slot, objects) in wanted where taps[slot] == nil {
            let d = CATapDescription(stereoMixdownOfProcesses: objects)
            d.name = "Submix: \(names[slot] ?? "app")"
            d.uuid = UUID()
            d.isPrivate = true
            d.muteBehavior = .mutedWhenTapped
            var id = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(d, &id)
            if status == noErr {
                taps[slot] = Tap(id: id, uid: d.uuid.uuidString, objects: objects)
                dlog("tap \(id) for \(names[slot] ?? "?") objects=\(objects)")
            } else {
                lastError = "Couldn't tap \(names[slot] ?? "app") (\(status))"
                dlog(lastError!)
            }
        }
        guard !taps.isEmpty else { return }
        startIO(outputUID: outputUID)
    }

    func shutdown() {
        stopIO()
        for tap in taps.values { AudioHardwareDestroyProcessTap(tap.id) }
        taps = [:]
    }

    private func startIO(outputUID: String) {
        let order = taps.keys.sorted()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Submix",
            kAudioAggregateDeviceUIDKey: aggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: order.map {
                [kAudioSubTapUIDKey: taps[$0]!.uid, kAudioSubTapDriftCompensationKey: true] as [String: Any]
            },
        ]
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else {
            lastError = "Couldn't open the output (\(status))"
            aggregate = AudioObjectID(kAudioObjectUnknown)
            return
        }

        let slots = UnsafeMutablePointer<Int32>.allocate(capacity: max(order.count, 1))
        for (i, slot) in order.enumerated() {
            slots[i] = Int32(slot)
            state[slot * Self.fields + 1] = 0      // fade in from silence
        }
        slotOrder = slots
        let ctx = RenderContext(state: state, left: left, right: right, slots: slots, tapCount: order.count)

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            MixEngine.render(ctx, input, output)
        }
        if status == noErr, let procID { status = AudioDeviceStart(aggregate, procID) }
        guard status == noErr else {
            lastError = "Couldn't start audio (\(status))"
            stopIO()
            return
        }
        deviceUID = outputUID
        dlog("running: \(order.count) tap(s) → \(outputUID)")
        if debugLogging {
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                let streams = CA.array(aggregate, kAudioDevicePropertyStreams, scope, of: AudioObjectID.self)
                for s in streams {
                    if let f = CA.value(s, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()) {
                        dlog("  \(scope == kAudioObjectPropertyScopeInput ? "in " : "out") stream \(s): \(f.mChannelsPerFrame)ch \(f.mSampleRate)Hz flags=\(f.mFormatFlags)")
                    }
                }
            }
        }
    }

    private func stopIO() {
        if aggregate != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregate, procID)
                AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        procID = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        deviceUID = nil
        slotOrder?.deallocate()
        slotOrder = nil
    }

    // MARK: Realtime callback

    /// The taps are the last `tapCount` input buffers, after any inputs the output device has.
    private static func render(_ c: RenderContext, _ input: UnsafePointer<AudioBufferList>,
                               _ output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard outs.count > 0 else { return }
        for i in 0..<outs.count {
            if let d = outs[i].mData { memset(d, 0, Int(outs[i].mDataByteSize)) }
        }
        let outChannels = Int(outs[0].mNumberChannels)
        guard outChannels > 0 else { return }
        let n = min(Int(outs[0].mDataByteSize) / (4 * outChannels), maxFrames)
        guard n > 0 else { return }
        vDSP_vclr(c.left, 1, vDSP_Length(n))
        vDSP_vclr(c.right, 1, vDSP_Length(n))

        let first = ins.count - c.tapCount
        if first >= 0 {
            for t in 0..<c.tapCount {
                let b = ins[first + t]
                let ch = Int(b.mNumberChannels)
                guard ch > 0, let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = min(n, Int(b.mDataByteSize) / (4 * ch))
                guard frames > 0 else { continue }
                let s = c.state + Int(c.slots[t]) * fields
                let target = s[0]
                var g = s[1]
                let step = (target - g) / Float(frames)
                let rightOffset = ch > 1 ? 1 : 0
                var peakL: Float = 0, peakR: Float = 0
                for i in 0..<frames {
                    g += step
                    let l = p[i * ch] * g
                    let r = p[i * ch + rightOffset] * g
                    c.left[i] += l
                    c.right[i] += r
                    peakL = max(peakL, abs(l))
                    peakR = max(peakR, abs(r))
                }
                s[1] = target
                if peakL > s[2] { s[2] = peakL }
                if peakR > s[3] { s[3] = peakR }
            }
        }

        // Master: gain, meter, then a hard ceiling so a hot sum can't wrap or blast.
        let m = c.state + masterSlot * fields
        let target = m[0]
        var g = m[1]
        let step = (target - g) / Float(n)
        var peakL: Float = 0, peakR: Float = 0
        for i in 0..<n {
            g += step
            let l = c.left[i] * g
            let r = c.right[i] * g
            peakL = max(peakL, abs(l))
            peakR = max(peakR, abs(r))
            c.left[i] = min(1, max(-1, l))
            c.right[i] = min(1, max(-1, r))
        }
        m[1] = target
        if peakL > m[2] { m[2] = peakL }
        if peakR > m[3] { m[3] = peakR }

        guard let o0 = outs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        if outChannels >= 2 {
            for i in 0..<n {
                o0[i * outChannels] = c.left[i]
                o0[i * outChannels + 1] = c.right[i]
            }
        } else if outs.count >= 2, let o1 = outs[1].mData?.assumingMemoryBound(to: Float.self) {
            let n1 = min(n, Int(outs[1].mDataByteSize) / 4)
            for i in 0..<n { o0[i] = c.left[i] }
            for i in 0..<n1 { o1[i] = c.right[i] }
        } else {
            for i in 0..<n { o0[i] = 0.5 * (c.left[i] + c.right[i]) }
        }
    }
}
