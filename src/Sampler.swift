import Foundation
import Observation

@Observable final class Sampler {
    var s = Snapshot()
    @ObservationIgnored var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible { opened() } else { schedule() }
        }
    }
    @ObservationIgnored var paused = false
    @ObservationIgnored var onTick: (() -> Void)?
    private let cpu = CPUReader(), net = NetReader(), smc = SMC(), energy = EnergyReader(), thermal = ThermalReader()
    private var slowW: Double?
    private var fastW = 0.0
    private var lastBattery: Date?
    private var timer: Timer?
    private var drivesRead: Date?

    init() {
        sampleBattery()
        schedule()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Sampler>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { if !me.visible { me.idleTick() } }
        }, ctx).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func schedule() {
        timer?.invalidate()
        let interval = visible ? 1.0 : 30.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.visible == true ? self?.tick() : self?.idleTick() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func opened() {
        _ = cpu.read(); _ = net.read()
        s.upHist = []; s.downHist = []
        schedule()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.visible == true { self?.tick() } }
    }

    private func idleTick() {
        sampleBattery()
        onTick?()
    }

    private func tick() {
        guard !paused else { return }
        let cores = cpu.read(), n = net.read()
        s.cores = cores; s.eCores = min(cpu.eCores, cores.count); s.cpu = avg(cores)
        (s.up, s.down, s.localIP) = n
        s.upHist = (s.upHist + [n.up]).suffix(30); s.downHist = (s.downHist + [n.down]).suffix(30)
        sampleBattery()
        refreshPanel()
        refreshDrives()
        onTick?()
    }

    private func refreshDrives() {
        guard drivesRead.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        drivesRead = Date()
        s.drives = Dictionary(s.volumes.compactMap { v in readDrive(path: v.path).map { (v.path, $0) } }) { a, _ in a }
    }

    private func sampleBattery() {
        let now = Date(), dt = lastBattery.map { now.timeIntervalSince($0) } ?? 1
        lastBattery = now
        var b = readBattery()
        if let w = smc.value("PSTR"), w > 0 { b.sysW = w }
        let draw = PowerState(b).bat
        if draw <= 0 { slowW = nil } else {
            let slow0 = slowW ?? draw
            let slow = slow0 + (draw - slow0) * min(1, dt / 300)
            fastW = slowW == nil ? draw : fastW + (draw - fastW) * min(1, dt / 20)
            slowW = slow
            b.avgW = slow + 0.5 * max(0, fastW - slow)
        }
        s.battery = b
    }

    func refreshPanel() {
        (s.ramUsed, s.ramTotal, s.swap, s.pressure) = readRAM()
        s.volumes = readVolumes()
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
