import Foundation
import IOKit

// private IOHIDEventSystem API (referenced from Stats)
@_silgen_name("IOHIDEventSystemClientCreate") private nonisolated func hidCreate(_ a: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private nonisolated func hidMatch(_ c: CFTypeRef, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private nonisolated func hidServices(_ c: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private nonisolated func hidProp(_ s: CFTypeRef, _ k: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent") private nonisolated func hidEvent(_ s: CFTypeRef, _ t: Int64, _ o: Int32, _ x: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue") private nonisolated func hidFloat(_ e: CFTypeRef, _ f: Int32) -> Double

nonisolated final class ThermalReader {
    private var client: CFTypeRef?
    private var services: [(name: String, svc: CFTypeRef)] = []

    init() {
        guard let c = hidCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        client = c
        _ = hidMatch(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = hidServices(c)?.takeRetainedValue() as? [CFTypeRef] ?? []
        services = list.map { (hidProp($0, "Product" as CFString)?.takeRetainedValue() as? String ?? "", $0) }
    }

    func read() -> [String: Double] {
        var sum: [String: (Double, Int)] = [:]
        for (name, svc) in services {
            guard let e = hidEvent(svc, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = hidFloat(e, 15 << 16)
            guard v > 0, v < 130 else { continue }
            let (s, n) = sum[name] ?? (0, 0); sum[name] = (s + v, n + 1)
        }
        return sum.mapValues { $0.0 / Double($0.1) }
    }
}
