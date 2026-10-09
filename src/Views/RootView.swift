import SwiftUI

enum Page {
    case cpu, gpu, ram, network, battery
    var title: LocalizedStringKey {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .ram: "Memory"; case .network: "Network"; case .battery: "Battery" }
    }
}

struct DetailView: View {
    let sampler: Sampler
    let page: Page

    var body: some View {
        let s = sampler.s
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .battery: BatteryDetail(sampler: sampler)
            case .cpu:
                Section_ { Row("Usage", pct(s.cpu)) }
                Section_ { CoreBars(cores: s.cores, eCores: s.eCores) }
                Hairline()
                Section_ { Row("Temperature", temp(s.cpuTemp)) }
            case .gpu:
                Section_ { Row("Model", s.gpuInfo.cores > 0 ? String(localized: "\(s.gpuInfo.model) · \(s.gpuInfo.cores) cores") : s.gpuInfo.model) }
                Hairline()
                Section_ {
                    Row("Usage", pct(s.gpuInfo.usage)); Row("Render", pct(s.gpuInfo.render)); Row("Tiler", pct(s.gpuInfo.tiler))
                    Row("Memory in use", bytes(s.gpuInfo.memUsed)); Row("Memory allocated", bytes(s.gpuInfo.memAlloc)); Row("Temperature", temp(s.gpuTemp))
                }
            case .ram:
                Section_ { Row("Used", bytes(s.ramUsed)); Row("Free", bytes(s.ramTotal - s.ramUsed)); Row("Total", bytes(s.ramTotal)); Row("Swap", bytes(s.swap)); Row("Pressure", s.pressure) }
            case .network:
                Section_ { Row("Connection", s.link); Row("Upload", bytes(s.up, rate: true)); Row("Download", bytes(s.down, rate: true)); Row("Local IP", s.localIP) }
                Hairline()
                Section_ { AxisGraph(up: s.upHist, down: s.downHist) }
            }
        }
        .padding(.bottom, 6).frame(width: 300)
    }
}

struct OverviewView: View {
    let sampler: Sampler
    let onSelect: (Page) -> Void

    var body: some View {
        let s = sampler.s, b = s.battery, p = PowerState(b)
        VStack(spacing: 0) {
            MenuButton { onSelect(.battery) } label: {
                HStack(spacing: 10) {
                    BatteryShape(percent: b.percent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pct(Double(b.percent) / 100)).font(.title3.weight(.semibold)).monospacedDigit()
                        Text(p.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let t = timeLine(b, p), !b.onAC || b.charging {
                             Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                }.padding(10)
            }
            Hairline().padding(.vertical, 4)
            HStack(spacing: 0) {
                ring(.cpu, s.cpu, .blue, temp(s.cpuTemp))
                ring(.gpu, s.gpuInfo.usage, .purple, temp(s.gpuTemp))
                ring(.ram, s.ramPct, .orange, bytes(s.ramUsed))
            }
            Hairline().padding(.vertical, 4)
            MenuButton { onSelect(.network) } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "↑ \(bytes(s.up, rate: true))").foregroundStyle(.red)
                        Text(verbatim: "↓ \(bytes(s.down, rate: true))").foregroundStyle(.blue)
                    }.font(.caption).monospacedDigit().frame(width: 100, alignment: .leading)
                    Sparkline(up: s.upHist, down: s.downHist).frame(height: 40)
                }.padding(10)
            }
        }
        .padding(.vertical, 6).frame(width: 300)
    }

    private func ring(_ p: Page, _ v: Double, _ c: Color, _ sub: String) -> some View {
        MenuButton { onSelect(p) } label: {
            VStack(spacing: 10) {
                Ring(value: v, color: c, size: 64)
                VStack(spacing: 3) {
                    Text(p.title).font(.callout.weight(.semibold))
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }.padding(.vertical, 8).frame(maxWidth: .infinity)
        }
    }
}

struct PanelRoot: View {
    let sampler: Sampler
    let page: Page?
    let onSelect: (Page?) -> Void
    let onSize: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let page {
                Color.clear.frame(height: 6)
                MenuButton { onSelect(nil) } label: {
                    HStack(spacing: 6) { Image(systemName: "chevron.left").font(.callout.weight(.semibold)); Text(page.title).font(.headline); Spacer() }.padding(10)
                }
                Color.clear.frame(height: 6)
                Hairline()
                DetailView(sampler: sampler, page: page)
            } else {
                OverviewView(sampler: sampler, onSelect: onSelect)
            }
        }
        .frame(width: 300).fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
