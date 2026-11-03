import SwiftUI

enum Page: String, Codable {
    case cpu, gpu, ram, storage, network, battery
    var title: LocalizedStringKey {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .ram: "Memory"; case .storage: "Storage"; case .network: "Network"; case .battery: "Battery" }
    }
}

extension Page {
    var color: Color {
        switch self { case .cpu: .blue; case .gpu: .purple; case .ram: .orange; case .storage: .green; case .network: .red; case .battery: .green }
    }
    func reading(_ s: Snapshot) -> (Double, String) {
        switch self {
        case .cpu: (s.cpu, temp(s.cpuTemp))
        case .gpu: (s.gpuInfo.usage, temp(s.gpuTemp))
        case .ram: (s.ramPct, bytes(s.ramUsed))
        default: (0, "")
        }
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
            case .storage:
                ForEach(Array(s.volumes.enumerated()), id: \.element.id) { i, v in
                    if i > 0 { Hairline() }
                    Section_ {
                        Text(verbatim: v.name).font(.headline)
                        Row("Used", bytes(v.used)); Row("Free", bytes(v.total - v.used)); Row("Total", bytes(v.total))
                        StatBar(value: v.fraction, color: .green).padding(.top, 2)
                        if let d = s.drives[v.path] {
                            VStack(alignment: .leading, spacing: 6) {
                                if let type = d.typeText { Row("Type", type) }
                                if let c = d.connectionText { Row("Connection", c) }
                                if let h = d.health { Row("Health", d.warning ? String(localized: "Needs attention") : "\(h) %") }
                                if let w = d.written { Row("Data written", driveBytes(w)) }
                            }.padding(.top, 10)
                        }
                    }
                }
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
    let state: PanelState
    let onSelect: (Page) -> Void
    @AppStorage(StatLayout.key) private var layout = StatLayout.default
    @State private var dragging: String?
    @State private var dragStart = CGRect.zero
    @State private var dragRole = Slot.Role.full
    @State private var dragOffset = CGSize.zero
    @State private var dragGrabX: CGFloat = 0
    @State private var lockedHeight: CGFloat?
    @State private var lastTarget: String?
    @State private var frames = FrameStore()

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
            }.allowsHitTesting(!state.editing)
            Hairline().padding(.vertical, 4)
            grid(s)
            if state.editing { editFooter }
        }
        .padding(.vertical, 6).frame(width: 300)
    }

    private func grid(_ s: Snapshot) -> some View {
        let arranged = layout.arranged()
        return TileFlow {
            ForEach(arranged, id: \.tile.id) { t, slot in
                Group {
                    if state.editing { editTile(t, slot, s) } else { content(t, slot.role, s) }
                }.slot(slot)
            }
        }
        .frame(width: 300).frame(minHeight: lockedHeight, alignment: .top)
        .coordinateSpace(name: "grid")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { frames.height = $0 }
        .overlay(alignment: .topLeading) {
            if let id = dragging, let t = layout.items.first(where: { $0.id == id }) {
                let isRing = t.kind == .ring, w = isRing ? min(dragStart.width, TileFlow.ringW) : dragStart.width
                content(t, dragRole, s)
                    .frame(width: w, height: dragStart.height)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .shadow(radius: 8, y: 2)
                    .offset(x: (isRing ? dragGrabX - w / 2 : dragStart.minX) + dragOffset.width, y: dragStart.minY + dragOffset.height)
                    .allowsHitTesting(false)
            }
        }
        .gesture(reorder(arranged), including: state.editing ? .all : .subviews)
        .contextMenu {
            if state.editing {
                Button("Add separator") { layout.items.append(.separator()) }
                Button("Reset layout") { layout = .default }
            }
        }
    }

    private func reorder(_ arranged: [(tile: Tile, slot: Slot)]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
            .onChanged { v in
                if dragging == nil {
                    guard let hit = arranged.first(where: { frames.rects[$0.tile.id]?.contains(v.startLocation) == true }), let r = frames.rects[hit.tile.id] else { return }
                    dragging = hit.tile.id; dragStart = r; dragRole = hit.slot.role; dragGrabX = v.startLocation.x; lastTarget = nil
                    lockedHeight = frames.height
                }
                guard let id = dragging else { return }
                dragOffset = v.translation
                if frames.rects[id]?.contains(v.location) == true { lastTarget = nil; return }
                guard let over = arranged.first(where: { $0.tile.id != id && frames.rects[$0.tile.id]?.contains(v.location) == true })?.tile.id, over != lastTarget else { return }
                lastTarget = over
                withAnimation(.snappy(duration: 0.25)) { layout.move(id, onto: over) }
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) { dragging = nil; dragOffset = .zero; lockedHeight = nil }
                lastTarget = nil
            }
    }

    @ViewBuilder private func content(_ t: Tile, _ role: Slot.Role, _ s: Snapshot) -> some View {
        if let p = t.page {
            if p == .network { networkGraph(s) }
            else if t.style == .ring { ring(t, p, s) }
            else if role == .stacked { compactBar(t, p, s) }
            else { bar(t, p, s) }
        } else { Hairline().padding(.vertical, state.editing ? 14 : 4) }
    }

    private func editTile(_ t: Tile, _ slot: Slot, _ s: Snapshot) -> some View {
        let lifted = dragging == t.id
        return content(t, slot.role, s).allowsHitTesting(false)
            .opacity(lifted ? 0 : 1)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(lifted ? Color.accentColor : Color.secondary.opacity(0.5), style: .init(lineWidth: lifted ? 2 : 1, dash: lifted ? [] : [4])).padding(3))
            .contentShape(.rect)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("grid")) } action: { frames.rects[t.id] = $0 }
            .contextMenu { menu(for: t) }
    }

    private func update(_ id: String, _ change: (inout Tile) -> Void) {
        if let i = layout.items.firstIndex(where: { $0.id == id }) { change(&layout.items[i]) }
    }

    @ViewBuilder private func menu(for t: Tile) -> some View {
        if let page = t.page {
            if page.styles.count > 1 {
                Picker("Style", selection: Binding(get: { t.style }, set: { s in update(t.id) { $0.style = s } })) {
                    ForEach(page.styles, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if page == .storage {
                let volumes = sampler.s.volumes
                Picker("Drive", selection: Binding(get: { t.volume ?? "/" }, set: { v in update(t.id) { $0.volume = v == "/" ? nil : v } })) {
                    ForEach(volumes) { Text(verbatim: $0.name).tag($0.path) }
                }
                Button("Add another drive") {
                    let used = Set(layout.items.filter { $0.page == .storage }.map { $0.volume ?? "/" })
                    if let i = layout.items.firstIndex(where: { $0.id == t.id }) {
                        layout.items.insert(.drive(volumes.first { !used.contains($0.path) }?.path ?? "/"), at: i + 1)
                    }
                }
            }
            Divider()
            if t.isExtraDrive {
                Button("Remove") { layout.items.removeAll { $0.id == t.id } }
            } else {
                Button("Hide") { update(t.id) { $0.enabled = false } }
            }
            Button("Add separator below") {
                if let i = layout.items.firstIndex(where: { $0.id == t.id }) { layout.items.insert(.separator(), at: i + 1) }
            }
        } else {
            Button("Remove separator") { layout.items.removeAll { $0.id == t.id } }
        }
    }

    @ViewBuilder private var editFooter: some View {
        let hidden = layout.items.filter { !$0.enabled && $0.page != nil }
        Hairline().padding(.vertical, 4)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Drag to rearrange. Right-click a tile for options.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { state.editing = false }
            }
            if !hidden.isEmpty {
                HStack(spacing: 6) {
                    Text("Hidden").font(.caption).foregroundStyle(.secondary)
                    ForEach(hidden) { t in
                        Button { update(t.id) { $0.enabled = true } } label: {
                            Text(t.page!.title).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: .capsule)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func name(_ t: Tile, _ p: Page, _ s: Snapshot) -> Text {
        if p == .storage, let path = t.volume { return Text(verbatim: s.volume(path)?.name ?? URL(fileURLWithPath: path).lastPathComponent) }
        return Text(p.title)
    }

    private func compactBar(_ t: Tile, _ p: Page, _ s: Snapshot) -> some View {
        let (v, sub) = t.reading(s)
        return MenuButton { onSelect(p) } label: {
            VStack(alignment: .leading, spacing: 5) {
                name(t, p, s).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                StatBar(value: v, color: p.color)
                Text(verbatim: "\(pct(v)) · \(sub)").font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func networkGraph(_ s: Snapshot) -> some View {
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

    @ViewBuilder private func ring(_ t: Tile, _ p: Page, _ s: Snapshot) -> some View {
        let (v, sub) = t.reading(s)
        MenuButton { onSelect(p) } label: {
            VStack(spacing: 10) {
                Ring(value: v, color: p.color, size: 52)
                VStack(spacing: 3) {
                    name(t, p, s).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }.padding(.vertical, 8).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func bar(_ t: Tile, _ p: Page, _ s: Snapshot) -> some View {
        let (v, sub) = t.reading(s)
        MenuButton { onSelect(p) } label: {
            VStack(spacing: 5) {
                HStack {
                    name(t, p, s).font(.callout.weight(.semibold))
                    Spacer()
                    Text(sub).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(pct(v)).font(.callout).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                StatBar(value: v, color: p.color)
            }.padding(.horizontal, 10).padding(.vertical, 7)
        }
    }
}

final class FrameStore {
    var rects: [String: CGRect] = [:]
    var height: CGFloat = 0
}

@Observable final class PanelState {
    var pinned = false
    var editing = false { didSet { onEditing?(editing) } }
    @ObservationIgnored var onEditing: ((Bool) -> Void)?
}

struct PanelRoot: View {
    let sampler: Sampler
    let state: PanelState
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
                OverviewView(sampler: sampler, state: state, onSelect: onSelect)
            }
        }
        .frame(width: 300).fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
