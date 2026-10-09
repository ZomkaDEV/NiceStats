import SwiftUI

func bytes(_ v: Double, rate: Bool = false) -> String {
    let f = ByteCountFormatter(); f.countStyle = .binary
    return f.string(fromByteCount: Int64(v)) + (rate ? "/s" : "")
}
func pct(_ v: Double) -> String { v.formatted(.percent.precision(.fractionLength(0))) }
func watts(_ w: Double) -> String { String(format: "%.1f W", locale: .current, abs(w)) }

struct Title: View {
    let text: LocalizedStringKey
    init(_ t: LocalizedStringKey) { text = t }
    var body: some View { Text(text).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
}

struct Row: View {
    let label: LocalizedStringKey, value: String
    init(_ l: LocalizedStringKey, _ v: String) { label = l; value = v }
    var body: some View { HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() } }
}

struct Section_<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Hairline: View { var body: some View { Divider().opacity(0.6).padding(.horizontal, 16) } }

struct MenuButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hover = false
    var body: some View {
        Button(action: action) { label.contentShape(.rect) }
            .buttonStyle(.plain)
            .background(.primary.opacity(hover ? 0.1 : 0), in: .rect(cornerRadius: 14))
            .padding(.horizontal, 6)
            .onHover { hover = $0 }
    }
}

struct Ring: View {
    let value: Double
    var color: Color = .blue
    var size: CGFloat = 56
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle().trim(from: 0, to: min(max(value, 0.005), 1)).stroke(color, style: .init(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(pct(value)).font(.callout.weight(.medium)).monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

struct BatteryShape: View {
    let percent: Int
    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.secondary, lineWidth: 2.5).frame(width: 70, height: 36)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4.5).fill(percent <= 20 ? .red : .green)
                        .frame(width: max(9, 61 * CGFloat(percent) / 100), height: 27).padding(.leading, 4.5)
                }
            Capsule().fill(.secondary).frame(width: 3, height: 12)
        }
    }
}

struct Sparkline: View {
    let up: [Double], down: [Double]
    var body: some View {
        let peak = max((up + down).max() ?? 0, 1024)
        Canvas { ctx, size in
            var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            for (d, c) in [(down, Color.blue), (up, Color.red)] where d.count > 1 {
                let pts = d.enumerated().map { i, v in
                    CGPoint(x: size.width * CGFloat(i + 30 - d.count) / 29, y: (size.height - 2) * (1 - min(v / peak, 1)) + 1)
                }
                var line = Path(); line.move(to: pts[0])
                for i in 1..<pts.count {
                    let m = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                    line.addQuadCurve(to: m, control: pts[i - 1])
                }
                line.addLine(to: pts[pts.count - 1])
                var area = line
                area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height)); area.addLine(to: CGPoint(x: pts[0].x, y: size.height)); area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [c.opacity(0.35), c.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(c), style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct PowerState {
    let bat: Double, ac: Double, charge: Double, status: String
    init(_ b: BatteryInfo) {
        let assist = b.onAC && !b.charging && b.battW < -0.5
        bat = !b.onAC ? b.sysW : assist ? min(b.sysW, -b.battW) : 0
        ac = b.onAC ? max(0, b.sysW - bat) : 0
        charge = b.charging ? max(0, b.adapterW - b.sysW) : 0
        status = b.charging ? String(localized: "Charging (\(watts(charge)))") : !b.onAC ? String(localized: "On battery")
            : assist ? String(localized: "Plugged in · Discharging") : String(localized: "Plugged in")
    }
}

struct FlowView: View {
    let b: BatteryInfo
    typealias Node = (icon: String, watts: Double, at: CGPoint)

    private static let top: CGFloat = 22, bottomInset: CGFloat = 38

    private var twoRows: Bool { let p = PowerState(b); return p.charge > 0.5 || (p.ac > 0.5 && p.bat > 0.5) }
    private var height: CGFloat { twoRows ? 120 : Self.top + Self.bottomInset }

    private func nodes(w: CGFloat) -> (left: [Node], right: [Node]) {
        let p = PowerState(b), lx: CGFloat = 34, rx = w - 34
        let top = Self.top, bottom = height - Self.bottomInset, mid = (top + bottom) / 2
        if p.charge > 0.5 {
            return ([("powerplug.fill", b.adapterW, CGPoint(x: lx, y: mid))],
                    [("battery.100percent.bolt", p.charge, CGPoint(x: rx, y: top)), (laptopSymbol, b.sysW, CGPoint(x: rx, y: bottom))])
        }
        var src: [(String, Double)] = []
        if p.ac > 0.5 { src.append(("powerplug.fill", p.ac)) }
        if p.bat > 0.5 { src.append(("battery.100percent", p.bat)) }
        if src.isEmpty { src = [("powerplug.fill", 0)] }
        let left = src.enumerated().map { i, e in (e.0, e.1, CGPoint(x: lx, y: src.count == 1 ? mid : (i == 0 ? top : bottom))) }
        return (left, [(laptopSymbol, b.sysW, CGPoint(x: rx, y: mid))])
    }

    var body: some View {
        GeometryReader { g in
            let (left, right) = nodes(w: g.size.width)
            ZStack {
                Canvas { ctx, _ in
                    for l in left { for r in right {
                        var path = Path()
                        let a = CGPoint(x: l.at.x + 20, y: l.at.y), z = CGPoint(x: r.at.x - 20, y: r.at.y), m = (a.x + z.x) / 2
                        path.move(to: a)
                        path.addCurve(to: z, control1: CGPoint(x: m, y: a.y), control2: CGPoint(x: m, y: z.y))
                        ctx.stroke(path, with: .color(.secondary.opacity(0.7)), style: .init(lineWidth: 2.5, lineCap: .round))
                    } }
                }
                ForEach(Array((left + right).enumerated()), id: \.offset) { _, n in
                    VStack(spacing: 2) {
                        Image(systemName: n.icon).font(.system(size: 16)).frame(width: 36, height: 36).background(.primary.opacity(0.1), in: .circle)
                        Text(watts(n.watts)).font(.caption.weight(.semibold)).monospacedDigit()
                    }.position(x: n.at.x, y: n.at.y + 8)
                }
            }
        }.frame(height: height)
    }
}

func minutesLeft(_ b: BatteryInfo, _ p: PowerState) -> Int? {
    if !b.charging, p.bat > 0.5, b.energyWh > 0, b.avgW > 0 { return Int(b.energyWh / b.avgW * 60) }
    return b.minutes
}

func clock(_ m: Int) -> String { "\(m / 60):\(String(format: "%02d", m % 60))" }

func timeLine(_ b: BatteryInfo, _ p: PowerState) -> String? {
    guard let m = minutesLeft(b, p) else { return nil }
    return b.charging ? String(localized: "\(clock(m)) until charged") : p.bat > 0.5 ? String(localized: "\(clock(m)) left") : nil
}

func temp(_ c: Double) -> String {
    guard c > 0 else { return notAvailable }
    return Locale.current.measurementSystem == .us ? String(format: "%.0f°F", locale: .current, c * 9 / 5 + 32) : String(format: "%.0f°C", locale: .current, c)
}

struct AxisGraph: View {
    let up: [Double], down: [Double]
    var body: some View {
        let peak = max((up + down).max() ?? 0, 1024)
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(bytes(peak, rate: true)); Spacer(); Text(bytes(peak / 2, rate: true)); Spacer(); Text(verbatim: "0")
                }.font(.caption2).foregroundStyle(.secondary).frame(width: 62, height: 90)
                Canvas { ctx, size in
                    gridlines(ctx, size)
                    for (d, c) in [(up, Color.red), (down, Color.blue)] {
                        var p = Path()
                        for (i, v) in d.enumerated() {
                            let pt = CGPoint(x: size.width * CGFloat(i + 30 - d.count) / 29, y: size.height * (1 - v / peak))
                            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                        }
                        ctx.stroke(p, with: .color(c), lineWidth: 1.5)
                    }
                }.frame(height: 90)
            }
            HStack { Text("30 s ago"); Spacer(); Text("now") }.font(.caption2).foregroundStyle(.secondary).padding(.leading, 68)
        }
    }
}

struct CoreBars: View {
    let cores: [Double], eCores: Int
    var body: some View {
        let plot: CGFloat = 60
        HStack(alignment: .top, spacing: 6) {
            ZStack(alignment: .trailing) {
                ForEach([1.0, 0.5, 0.0], id: \.self) { f in
                    Text(pct(f)).font(.caption2).foregroundStyle(.secondary).position(x: 17, y: plot * (1 - f))
                }
            }.frame(width: 34, height: plot)
            VStack(spacing: 3) {
                ZStack(alignment: .bottom) {
                    Canvas { ctx, size in
                        gridlines(ctx, size)
                    }
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                            RoundedRectangle(cornerRadius: 3).fill(i < eCores ? .cyan : .orange).frame(height: max(3, plot * v))
                        }
                    }
                }.frame(height: plot)
                HStack(spacing: 3) {
                    ForEach(0..<cores.count, id: \.self) { i in
                        Text(verbatim: i < eCores ? "\(i + 1)E" : "\(i - eCores + 1)P").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
        }.padding(.vertical, 6)
    }
}

let laptopSymbol: String = {
    var n = 0
    sysctlbyname("hw.model", nil, &n, nil, 0)
    var buf = [CChar](repeating: 0, count: n)
    sysctlbyname("hw.model", &buf, &n, nil, 0)
    let model = String(cString: buf)
    let classic = ["MacBookAir10,1", "MacBookPro17,1", "Mac14,7"].contains(model)
    return classic ? "laptopcomputer" : "macbook"
}()

func gridlines(_ ctx: GraphicsContext, _ size: CGSize) {
    for f in [0.0, 0.5, 1.0] {
        var g = Path(); g.move(to: CGPoint(x: 0, y: size.height * (1 - f))); g.addLine(to: CGPoint(x: size.width, y: size.height * (1 - f)))
        ctx.stroke(g, with: .color(.secondary.opacity(f == 0 ? 0.6 : 0.25)), lineWidth: 0.5)
    }
}
