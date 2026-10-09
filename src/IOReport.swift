import Foundation

/// Grapping power per component from IOReport (referenced from Stats, see README)
nonisolated final class EnergyReader {
    private typealias CopyIn = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias Sub = @convention(c) (CFAllocator?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias Samples = @convention(c) (OpaquePointer, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Name = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Val = @convention(c) (CFDictionary, Int32) -> Int64

    private let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
    private func f<T>(_ n: String, _ t: T.Type) -> T? { h.flatMap { dlsym($0, n) }.map { unsafeBitCast($0, to: T.self) } }

    private var sub: OpaquePointer?
    private var chans: CFMutableDictionary?
    private var prev: ([String: Double], Date)?

    init() {
        guard let copy = f("IOReportCopyChannelsInGroup", CopyIn.self), let mk = f("IOReportCreateSubscription", Sub.self),
              let c = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        var out: Unmanaged<CFMutableDictionary>?
        sub = mk(nil, c, &out, 0, nil); chans = c
    }

    func read() -> [String: Double] {
        guard let sub, let chans, let take = f("IOReportCreateSamples", Samples.self), let name = f("IOReportChannelGetChannelName", Name.self),
              let unit = f("IOReportChannelGetUnitLabel", Name.self), let val = f("IOReportSimpleGetIntegerValue", Val.self),
              let list = take(sub, chans, nil)?.takeRetainedValue() as? [String: Any], let items = list["IOReportChannels"] as? [CFDictionary] else { return [:] }
        let now = Date()
        var energy: [String: Double] = [:]
        // i just realized this is essentially what i did for my physics ia. almost threw up at that thought
        for ch in items {
            let n = name(ch)?.takeUnretainedValue() as String? ?? ""
            let scale: Double = switch unit(ch)?.takeUnretainedValue() as String? { case "mJ": 1e-3; case "uJ": 1e-6; case "nJ": 1e-9; default: 0 }
            energy[n, default: 0] += Double(val(ch, 0)) * scale
        }
        defer { prev = (energy, now) }
        guard let (p, t) = prev, now > t, now.timeIntervalSince(t) < 3 else { return [:] }
        let dt = now.timeIntervalSince(t)
        return energy.reduce(into: [:]) { $0[$1.key] = max(0, $1.value - (p[$1.key] ?? $1.value)) / dt }
    }
}
