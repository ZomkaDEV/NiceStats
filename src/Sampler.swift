import Foundation
import Observation

@Observable final class Sampler {
    var s = Snapshot()
    @ObservationIgnored var visible = false
    @ObservationIgnored var onTick: (() -> Void)?
    private let cpu = CPUReader(), net = NetReader(), smc = SMC(), energy = EnergyReader(), thermal = ThermalReader()
    private var slowW: Double?
    private var fastW = 0.0

    init() {
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        let cores = cpu.read(), n = net.read()
        s.cores = cores; s.eCores = min(cpu.eCores, cores.count); s.cpu = avg(cores)
        (s.up, s.down, s.localIP) = n
        s.upHist = (s.upHist + [n.up]).suffix(30); s.downHist = (s.downHist + [n.down]).suffix(30)

        var b = readBattery()
        if let w = smc.value("PSTR"), w > 0 { b.sysW = w }
        let draw = PowerState(b).bat
        if draw <= 0 { slowW = nil } else {
            let slow = (slowW ?? draw) + (draw - (slowW ?? draw)) / 300
            fastW = slowW == nil ? draw : fastW + (draw - fastW) / 20
            slowW = slow
            b.avgW = slow + 0.5 * max(0, fastW - slow)
        }
        s.battery = b
        if visible { refreshPanel() }
        onTick?()
    }

    func refreshPanel() {
        (s.ramUsed, s.ramTotal, s.swap, s.pressure) = readRAM()
        s.gpuInfo = readGPU()
        s.link = readLink()
        s.cpuTemp = avg(thermal.read().filter { $0.key.hasPrefix("PMU tdie") }.map(\.value))
        s.gpuTemp = avg(["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k"].compactMap { smc.value($0) }.filter { $0 > 0 })
        if let t = smc.value("TB0T") ?? smc.value("TB1T") { s.battery.tempC = t }
        s.battery.gpuW = energy.read()["GPU Energy"] ?? s.battery.gpuW
        s.battery.displayW = smc.value("PDBR") ?? 0
        s.battery.cpuW = max(0, (smc.value("PHPC") ?? 0) - s.battery.gpuW)
    }
}

private func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
