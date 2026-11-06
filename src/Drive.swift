import Foundation
import IOKit

struct DriveInfo {
    var solidState: Bool?
    var nvme = false
    var interconnect: String?
    var external: Bool?
    var health: Int?
    var warning = false
    var written: Double?

    var typeText: String? {
        let parts = [solidState.map { $0 ? "SSD" : "HDD" }, nvme ? "NVMe" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var connectionText: String? {
        let parts = [external.map { $0 ? String(localized: "External") : String(localized: "Internal") }, interconnect].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

func driveBytes(_ v: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .decimal) }

private func className(_ e: io_object_t) -> String {
    var b = [CChar](repeating: 0, count: 128)
    IOObjectGetClass(e, &b)
    return String(cString: b)
}

func readDrive(path: String) -> DriveInfo? {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return nil }
    let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    var cur = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, (from as NSString).lastPathComponent))
    var device: io_registry_entry_t = 0
    for _ in 0..<16 where cur != 0 {
        if IOObjectConformsTo(cur, "IOBlockStorageDevice") != 0 { device = cur; break }
        var parent: io_registry_entry_t = 0
        IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent)
        IOObjectRelease(cur); cur = parent
    }
    guard device != 0 else { if cur != 0 { IOObjectRelease(cur) }; return nil }
    defer { IOObjectRelease(device) }

    func prop(_ key: String, _ sub: String) -> Any? {
        (IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any])?[sub]
    }
    var info = DriveInfo()
    info.nvme = className(device).contains("NVMe")
    switch prop("Device Characteristics", "Medium Type") as? String {
    case "Solid State": info.solidState = true
    case "Rotational": info.solidState = false
    default: break
    }
    info.interconnect = prop("Protocol Characteristics", "Physical Interconnect") as? String
    switch prop("Protocol Characteristics", "Physical Interconnect Location") as? String {
    case "Internal": info.external = false
    case "External": info.external = true
    default: break
    }
    if info.nvme, let s = readNVMeSMART(device) {
        info.health = max(0, 100 - s.percentUsed)
        info.warning = s.critical != 0
        info.written = s.unitsWritten * 512_000
    }
    return info
}

private struct SmartVtbl {
    var reserved: UnsafeMutableRawPointer?
    var queryInterface: UnsafeMutableRawPointer?
    var addRef: UnsafeMutableRawPointer?
    var release: (@convention(c) (UnsafeMutableRawPointer?) -> UInt32)?
    var version: UInt16
    var revision: UInt16
    var smartReadData: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn)?
}

private func readNVMeSMART(_ service: io_service_t) -> (percentUsed: Int, critical: UInt8, unitsWritten: Double)? {
    let typeID = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    let ifaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    let plugID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    guard IOCreatePlugInInterfaceForService(service, typeID, plugID, &plugin, &score) == KERN_SUCCESS, let plugin else { return nil }
    defer { IODestroyPlugInInterface(plugin) }
    var out: LPVOID?
    guard plugin.pointee!.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(ifaceID), &out) == 0, let out else { return nil }
    let iface = out.assumingMemoryBound(to: UnsafeMutablePointer<SmartVtbl>.self)
    defer { _ = iface.pointee.pointee.release?(iface) }
    var buf = [UInt8](repeating: 0, count: 512)
    let rc = buf.withUnsafeMutableBytes { iface.pointee.pointee.smartReadData?(iface, $0.baseAddress) ?? -1 }
    guard rc == 0 else { return nil }
    let written = (0..<8).reduce(0.0) { $0 + Double(buf[48 + $1]) * pow(256, Double($1)) }
    return (Int(buf[5]), buf[0], written)
}
