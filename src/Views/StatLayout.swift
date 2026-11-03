import SwiftUI

enum StatStyle: String, Codable {
    case ring, bar, graph
    var title: LocalizedStringKey {
        switch self { case .ring: "Ring"; case .bar: "Bar"; case .graph: "Graph" }
    }
}

extension Page {
    var styles: [StatStyle] { self == .network ? [.graph] : [.ring, .bar] }
}

struct Tile: Codable, Identifiable {
    enum Kind { case ring, bar, wide }

    var page: Page?
    var style: StatStyle
    var enabled = true
    var volume: String?
    private var uid: String?
    var id: String { uid ?? page?.rawValue ?? "" }
    var isExtraDrive: Bool { page == .storage && uid != nil }

    var kind: Kind { page == nil || page == .network ? .wide : style == .ring ? .ring : .bar }

    init(page: Page) { self.page = page; style = page.styles[0] }
    static func drive(_ path: String) -> Tile {
        var t = Tile(page: .storage)
        t.uid = UUID().uuidString; t.volume = path
        return t
    }
    static func separator() -> Tile {
        var t = Tile(page: .cpu)
        t.page = nil; t.uid = UUID().uuidString; t.style = .bar
        return t
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        page = try c.decodeIfPresent(Page.self, forKey: .page)
        uid = try c.decodeIfPresent(String.self, forKey: .uid)
        volume = try c.decodeIfPresent(String.self, forKey: .volume)
        style = try c.decodeIfPresent(StatStyle.self, forKey: .style) ?? .bar
        if let page, !page.styles.contains(style) { style = page.styles[0] }
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

nonisolated struct Slot {
    enum Role: Equatable {
        case full
        case ringFill
        case ringFixed
        case stacked
    }
    var row: Int
    var role: Role
}

struct StatLayout: RawRepresentable {
    static let key = "statLayoutV3"
    static let stats: [Page] = [.cpu, .gpu, .ram, .storage, .network]
    static let `default` = StatLayout(items: stats.dropLast().map { Tile(page: $0) } + [.separator(), Tile(page: .network)])

    var items: [Tile]

    init(items: [Tile]) { self.items = items }
    init?(rawValue: String) {
        guard let d = rawValue.data(using: .utf8), let decoded = try? JSONDecoder().decode([Tile].self, from: d) else { return nil }
        var seen = Set<Page>()
        let kept = decoded.filter { t in
            guard let p = t.page else { return true }
            guard Self.stats.contains(p) else { return false }
            return t.isExtraDrive || seen.insert(p).inserted
        }
        items = kept + Self.stats.filter { !seen.contains($0) }.map { Tile(page: $0) }
    }
    var rawValue: String { (try? JSONEncoder().encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    private struct FlowRow { var rings: [Tile] = [], bars: [Tile] = [], wide: Tile? }

    private var flowRows: [FlowRow] {
        var rows: [FlowRow] = [], cur = FlowRow()
        func flush() { if !cur.rings.isEmpty || !cur.bars.isEmpty { rows.append(cur) }; cur = FlowRow() }
        for t in items where t.enabled {
            switch t.kind {
            case .wide: flush(); rows.append(FlowRow(wide: t))
            case .ring:
                if cur.rings.count >= 4 || (!cur.bars.isEmpty && cur.rings.count >= 2) || cur.bars.count > 2 { flush() }
                cur.rings.append(t)
            case .bar:
                if !cur.rings.isEmpty && cur.bars.count >= 2 { flush() }
                cur.bars.append(t)
            }
        }
        flush()
        return rows
    }

    func arranged() -> [(tile: Tile, slot: Slot)] {
        var slots: [String: Slot] = [:], n = 0
        for r in flowRows {
            if let w = r.wide {
                slots[w.id] = Slot(row: n, role: .full); n += 1
            } else if r.bars.isEmpty {
                r.rings.forEach { slots[$0.id] = Slot(row: n, role: .ringFill) }; n += 1
            } else if r.rings.isEmpty {
                for b in r.bars { slots[b.id] = Slot(row: n, role: .full); n += 1 }
            } else {
                r.rings.forEach { slots[$0.id] = Slot(row: n, role: .ringFixed) }
                r.bars.forEach { slots[$0.id] = Slot(row: n, role: .stacked) }
                n += 1
            }
        }
        return items.compactMap { t in slots[t.id].map { (t, $0) } }
    }

    mutating func move(_ id: String, onto target: String) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == target }) else { return }
        items.insert(items.remove(at: from), at: to)
    }
}

private nonisolated struct SlotKey: LayoutValueKey { static let defaultValue = Slot(row: 0, role: .full) }

extension View {
    func slot(_ s: Slot) -> some View { layoutValue(key: SlotKey.self, value: s) }
}

struct TileFlow: Layout {
    static let ringW: CGFloat = 84

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        return CGSize(width: w, height: arrange(w, subviews).height)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in arrange(b.width, subviews).frames.enumerated() {
            subviews[i].place(at: CGPoint(x: b.minX + f.minX, y: b.minY + f.minY), anchor: .topLeading, proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }

    private func arrange(_ W: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        let rows = Dictionary(grouping: subviews.indices) { subviews[$0][SlotKey.self].row }
        func height(_ i: Int, _ w: CGFloat) -> CGFloat { subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        var y: CGFloat = 0
        for r in rows.keys.sorted() {
            let idx = rows[r]!
            func with(_ role: Slot.Role) -> [Int] { idx.filter { subviews[$0][SlotKey.self].role == role } }
            let full = with(.full), fill = with(.ringFill), fixed = with(.ringFixed), stacked = with(.stacked)
            var h: CGFloat = 0
            if let i = full.first {
                h = height(i, W)
                frames[i] = CGRect(x: 0, y: y, width: W, height: h)
            } else if !fill.isEmpty {
                let w = W / CGFloat(fill.count), hs = fill.map { height($0, w) }
                h = hs.max() ?? 0
                for (k, i) in fill.enumerated() { frames[i] = CGRect(x: CGFloat(k) * w, y: y + (h - hs[k]) / 2, width: w, height: hs[k]) }
            } else {
                let rw = Self.ringW, sw = W - rw * CGFloat(fixed.count)
                let rhs = fixed.map { height($0, rw) }, shs = stacked.map { height($0, sw) }
                let stackH = shs.reduce(0, +)
                h = max(rhs.max() ?? 0, stackH)
                for (k, i) in fixed.enumerated() { frames[i] = CGRect(x: CGFloat(k) * rw, y: y + (h - rhs[k]) / 2, width: rw, height: rhs[k]) }
                var sy = y + (h - stackH) / 2
                for (k, i) in stacked.enumerated() { frames[i] = CGRect(x: rw * CGFloat(fixed.count), y: sy, width: sw, height: shs[k]); sy += shs[k] }
            }
            y += h
        }
        return (frames, y)
    }
}

extension Tile {
    func reading(_ s: Snapshot) -> (Double, String) {
        guard let page else { return (0, "") }
        if page == .storage {
            guard let v = s.volume(volume) else { return (0, String(localized: "Not connected")) }
            return (v.fraction, bytes(v.used))
        }
        return page.reading(s)
    }
}
