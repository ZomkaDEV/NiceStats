import Foundation
import IOKit

/// minimal AppleSMC reader (referenced from Stats, see README).
nonisolated final class SMC {
    private struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttr: UInt8 = 0
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)?] = [:]

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        IOServiceOpen(svc, mach_task_self_, 0, &conn)
        IOObjectRelease(svc)
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ i: inout KeyData) -> KeyData? {
        var o = KeyData(); var n = MemoryLayout<KeyData>.stride
        guard IOConnectCallStructMethod(conn, 2, &i, n, &o, &n) == KERN_SUCCESS else { return nil }
        return o
    }

    func value(_ name: String) -> Double? {
        guard conn != 0, name.utf8.count == 4 else { return nil }
        let key = name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var inp = KeyData(); inp.key = key
        if infoCache[key] == nil {
            inp.data8 = 9
            guard let o = call(&inp) else { return nil }
            if o.result == 0x84 { infoCache[key] = .some(nil); return nil }
            guard o.result == 0 else { return nil }
            infoCache[key] = (o.dataSize, o.dataType)
        }
        guard let info = infoCache[key] ?? nil else { return nil }
        inp.dataSize = info.size; inp.data8 = 5
        guard var o = call(&inp), o.result == 0 else { return nil }
        let b = withUnsafeBytes(of: &o.bytes) { Array($0) }
        switch String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: info.type >> $0) }, as: UTF8.self) {
        case "flt ": return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ": return Double(b[0])
        case "ui16": return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32": return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "sp78": return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default: return nil
        }
    }
}
