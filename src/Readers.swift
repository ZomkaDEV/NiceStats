import Foundation
import IOKit
import IOKit.ps
import CoreWLAN
import SystemConfiguration

/// Parts were referenced from Stats, see README.

let notAvailable = String(localized: "N/A")

struct BatteryInfo {
    var percent = 0, cycles = 0, maxMAh = 0, designMAh = 0, currentMAh = 0
    var charging = false, onAC = false
    var minutes: Int?
    var volts = 0.0, tempC = 0.0
    var cpuW = 0.0, gpuW = 0.0, displayW = 0.0
    var avgW = 0.0
    var sysW = 0.0, adapterW = 0.0, battW = 0.0
    var energyWh: Double { Double(currentMAh) / 1000 * volts }
    var health: Int { designMAh > 0 ? min(100, maxMAh * 100 / designMAh) : 100 }
}


struct Snapshot {
    var battery = BatteryInfo()
    var cpu = 0.0
    var cores: [Double] = [], eCores = 0
    var gpuInfo = GPUInfo()
    var cpuTemp = 0.0, gpuTemp = 0.0
    var ramUsed = 0.0, ramTotal = 1.0, swap = 0.0, pressure = String(localized: "Normal")
    var up = 0.0, down = 0.0, localIP = notAvailable
    var link = notAvailable
    var upHist: [Double] = [], downHist: [Double] = []
    var ramPct: Double { ramUsed / ramTotal }
}

private func sysctlInt(_ name: String) -> Int {
    var v: Int32 = 0; var n = MemoryLayout<Int32>.size
    sysctlbyname(name, &v, &n, nil, 0)
    return Int(v)
}

final class CPUReader {
    private var prev: [[UInt32]] = []
    let eCores = sysctlInt("hw.perflevel1.logicalcpu")

    func read() -> [Double] {
        var n: natural_t = 0, cnt: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let cur = (0..<Int(n)).map { i in (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[i * Int(CPU_STATE_MAX) + $0]) } }
        defer { prev = cur }
        guard prev.count == cur.count else { return Array(repeating: 0, count: cur.count) }
        return zip(cur, prev).map { c, p in
            let d = (0..<4).map { Double(c[$0] &- p[$0]) }
            let total = d.reduce(0, +)
            return total > 0 ? (total - d[Int(CPU_STATE_IDLE)]) / total : 0
        }
    }
}

final class NetReader {
    private var last: (bytes: [String: (i: UInt32, o: UInt32)], t: Date)?

    func read() -> (up: Double, down: Double, ip: String) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0, notAvailable) }
        defer { freeifaddrs(head) }
        var bytes: [String: (i: UInt32, o: UInt32)] = [:], ip: String?
        for p in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let a = p?.pointee, let sa = a.ifa_addr else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            if Int32(sa.pointee.sa_family) == AF_LINK, let d = a.ifa_data?.assumingMemoryBound(to: if_data.self) {
                bytes[name] = (d.pointee.ifi_ibytes, d.pointee.ifi_obytes)
            } else if Int32(sa.pointee.sa_family) == AF_INET, ip == nil {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                ip = String(cString: buf)
            }
        }
        let now = Date()
        defer { last = (bytes, now) }
        guard let l = last, now > l.t else { return (0, 0, ip ?? notAvailable) }
        var down = 0.0, up = 0.0
        for (n, c) in bytes {
            guard let p = l.bytes[n] else { continue }
            if c.i >= p.i { down += Double(c.i - p.i) }
            if c.o >= p.o { up += Double(c.o - p.o) }
        }
        let dt = now.timeIntervalSince(l.t)
        return (up / dt, down / dt, ip ?? notAvailable)
    }
}

func readRAM() -> (used: Double, total: Double, swap: Double, pressure: String) {
    var s = vm_statistics64()
    var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
    }
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    var sw = xsw_usage(); var n = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &sw, &n, nil, 0)
    let pr = sysctlInt("kern.memorystatus_vm_pressure_level")
    let pages = Double(s.active_count) + Double(s.inactive_count) + Double(s.speculative_count)
        + Double(s.wire_count) + Double(s.compressor_page_count) - Double(s.purgeable_count) - Double(s.external_page_count)
    return (ok == KERN_SUCCESS ? pages * Double(getpagesize()) : 0, total, Double(sw.xsu_used),
            pr >= 4 ? String(localized: "Critical") : pr >= 2 ? String(localized: "Warning") : String(localized: "Normal"))
}

struct GPUInfo {
    var usage = 0.0, render = 0.0, tiler = 0.0
    var memUsed = 0.0, memAlloc = 0.0
    var model = notAvailable, cores = 0
}

func readGPU() -> GPUInfo {
    var g = GPUInfo()
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return g }
    defer { IOObjectRelease(it) }
    while case let e = IOIteratorNext(it), e != 0 {
        defer { IOObjectRelease(e) }
        func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        guard let st = prop("PerformanceStatistics") as? [String: Any] else { continue }
        func n(_ k: String) -> Double? { (st[k] as? NSNumber)?.doubleValue }
        g.usage = max(g.usage, (n("Device Utilization %") ?? n("GPU Activity(%)") ?? 0) / 100)
        g.render = max(g.render, (n("Renderer Utilization %") ?? 0) / 100)
        g.tiler = max(g.tiler, (n("Tiler Utilization %") ?? 0) / 100)
        g.memUsed += n("In use system memory") ?? 0
        g.memAlloc += n("Alloc system memory") ?? 0
        if let m = prop("model") as? String { g.model = m }
        if let c = prop("gpu-core-count") as? NSNumber { g.cores = c.intValue }
    }
    return g
}

func readBattery() -> BatteryInfo {
    var b = BatteryInfo()
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    for ps in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
        guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        b.percent = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        b.charging = d[kIOPSIsChargingKey] as? Bool ?? false
        b.onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let m = d[b.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
        b.minutes = m > 0 ? m : nil
    }
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return b }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let p = props?.takeRetainedValue() as? [String: Any] else { return b }
    func num(_ k: String) -> Double { (p[k] as? NSNumber)?.doubleValue ?? 0 }
    b.cycles = Int(num("CycleCount"))
    let bd = p["BatteryData"] as? [String: Any] ?? [:]
    func bnum(_ k: String) -> Double { (bd[k] as? NSNumber)?.doubleValue ?? 0 }
    b.maxMAh = Int([num("AppleRawMaxCapacity"), bnum("NominalChargeCapacity"), bnum("FullChargeCapacity")].first { $0 > 0 } ?? 0)
    b.currentMAh = Int([num("AppleRawCurrentCapacity"), bnum("RemainingCapacity")].first { $0 > 0 } ?? 0)
    b.designMAh = Int([num("DesignCapacity"), bnum("DesignCapacity")].first { $0 > 0 } ?? 0)
    func signed(_ n: Any?) -> Double { Double(Int64(bitPattern: (n as? NSNumber)?.uint64Value ?? 0)) }
    if let t = p["PowerTelemetryData"] as? [String: Any] {
        b.sysW = signed(t["SystemLoad"]) / 1000
        b.adapterW = signed(t["SystemPowerIn"]) / 1000
        b.battW = signed(t["BatteryPower"]) / 1000
    }
    b.volts = num("Voltage") / 1000
    b.tempC = num("Temperature") / 100
    return b
}

func readLink() -> String {
    let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    guard let name = global?["PrimaryInterface"] as? String else { return String(localized: "Not connected") }
    func rate(_ bps: Double) -> String { bps >= 1e9 ? String(format: "%g Gbit/s", bps / 1e9) : String(format: "%.0f Mbit/s", bps / 1e6) }

    if CWWiFiClient.shared().interfaceNames()?.contains(name) == true, let w = CWWiFiClient.shared().interface(withName: name) {
        let gen: String = switch w.activePHYMode() {
        case .mode11ax: "Wi-Fi 6"; case .mode11ac: "Wi-Fi 5"; case .mode11n: "Wi-Fi 4"
        default: "Wi-Fi"
        }
        let band: String? = switch w.wlanChannel()?.channelBand {
        case .band2GHz: "2.4 GHz"; case .band5GHz: "5 GHz"; case .band6GHz: "6 GHz"; default: nil
        }
        return [gen, band].compactMap { $0 }.joined(separator: " · ")
    }

    var head: UnsafeMutablePointer<ifaddrs>?
    var baud = 0.0
    if getifaddrs(&head) == 0 {
        for p in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let a = p?.pointee, String(cString: a.ifa_name) == name, let sa = a.ifa_addr, Int32(sa.pointee.sa_family) == AF_LINK,
                  let d = a.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            baud = Double(d.pointee.ifi_baudrate)
        }
        freeifaddrs(head)
    }
    let kind = name.hasPrefix("en") ? String(localized: "Ethernet") : name.hasPrefix("utun") ? String(localized: "VPN") : name.hasPrefix("bridge") ? String(localized: "Thunderbolt Bridge") : name
    return baud > 0 ? "\(kind) · \(rate(baud))" : kind
}
