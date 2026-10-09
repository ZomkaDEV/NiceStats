import SwiftUI

struct BatteryDetail: View {
    let sampler: Sampler

    var body: some View {
        let s = sampler.s, b = s.battery
        let p = PowerState(b)

        Section_ {
            HStack(spacing: 10) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(b.percent <= 20 ? .red : .green).frame(width: g.size.width * CGFloat(min(max(b.percent, 0), 100)) / 100)
                    }
                }.frame(height: 10)
                Text(pct(Double(b.percent) / 100)).font(.headline).monospacedDigit()
            }
            Text(timeLine(b, p).map { "\(p.status) · \($0)" } ?? p.status).font(.callout).foregroundStyle(.secondary)
        }
        Hairline()
        Section_ { Title("Power"); FlowView(b: b) }
        Hairline()
        Section_ {
            Title("Usage")
            ForEach([(String(localized: "CPU"), b.cpuW, Color.cyan), (String(localized: "GPU"), b.gpuW, .purple), (String(localized: "Display"), b.displayW, .yellow),
                     (String(localized: "Other"), max(0, b.sysW - b.cpuW - b.gpuW - b.displayW), .gray)], id: \.0) { n, w, c in
                HStack(spacing: 8) {
                    Text(verbatim: n).frame(width: 64, alignment: .leading)
                    GeometryReader { g in Capsule().fill(c.opacity(0.8)).frame(width: g.size.width * CGFloat(min(1, w / max(b.sysW, 1)))) }.frame(height: 6)
                    Text(watts(w)).foregroundStyle(.secondary).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
        }
        Hairline()
        Section_ {
            Title("Battery")
            Row("Current capacity", String(format: "%d mAh", b.currentMAh))
            Row("Charged capacity", "\(b.maxMAh) mAh (\(pct(Double(b.health) / 100)))")
            Row("Designed capacity", "\(b.designMAh) mAh")
            if let m = minutesLeft(b, p) { Row(b.charging ? "Time to charge" : "Time left", clock(m)) }
            Row("Cycles", "\(b.cycles)")
            Row("Voltage", String(format: "%.2f V", b.volts)); Row("Temperature", temp(b.tempC))
        }
    }
}
