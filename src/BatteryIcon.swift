import AppKit

/// Entirely made by Sonnet 5.5. (Referenced from Ampere, see README)
func batteryIcon(percent: Int, charging: Bool, plugged: Bool) -> NSImage {
    let showBolt = charging || plugged
    let bodyW: CGFloat = 29, r: CGFloat = 3.5
    let size = NSSize(width: bodyW + 4, height: 14)
    let p = CGFloat(min(max(percent, 0), 100)) / 100
    let img = NSImage(size: size, flipped: false) { _ in
        let fillColor: NSColor = charging ? .systemGreen : ProcessInfo.processInfo.isLowPowerModeEnabled ? .systemYellow : percent <= 20 ? .systemRed : .labelColor
        let body = NSRect(x: 0, y: 0, width: bodyW, height: size.height)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)

        NSColor.labelColor.withAlphaComponent(0.4).setFill(); bodyPath.fill()

        NSGraphicsContext.saveGraphicsState()
        bodyPath.addClip()
        fillColor.setFill()
        let w = p > 0.97 ? bodyW : max(bodyW * p, 2 * r)
        if p > 0.82 { NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: size.height), xRadius: r, yRadius: r).fill() }
        else { NSRect(x: 0, y: 0, width: w, height: size.height).fill() }
        NSGraphicsContext.restoreGraphicsState()

        (p > 0.97 ? fillColor : NSColor.labelColor.withAlphaComponent(0.4)).setFill()
        NSBezierPath(roundedRect: NSRect(x: bodyW + 1, y: size.height / 2 - 2.5, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()

        let base = NSFont.menuBarFont(ofSize: 10)
        let font = NSFont(descriptor: base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]]), size: base.pointSize) ?? base
        let text = NSAttributedString(string: "\(percent)", attributes: [.font: font, .foregroundColor: charging ? NSColor.black : NSColor.white])
        let boltH: CGFloat = 10, boltW = boltH * 0.6
        let total = text.size().width + (showBolt ? boltW + 1 : 0)
        let x = (bodyW - total) / 2
        let y = (((size.height - font.capHeight) / 2 + font.descender - 1.0) * 2).rounded() / 2

        if !charging { NSGraphicsContext.current?.compositingOperation = .destinationOut }
        text.draw(at: NSPoint(x: x, y: y))
        if showBolt {
            let bx = x + text.size().width + 1, by = (size.height - boltH) / 2
            let pts: [(CGFloat, CGFloat)] = [(0.70, 1.0), (0.08, 0.38), (0.42, 0.38), (0.30, 0.0), (0.92, 0.62), (0.58, 0.62)]
            let path = NSBezierPath()
            for (i, q) in pts.enumerated() { let pt = NSPoint(x: bx + q.0 * boltW, y: by + q.1 * boltH); i == 0 ? path.move(to: pt) : path.line(to: pt) }
            path.close(); path.lineJoinStyle = .round; path.lineWidth = 0.5
            NSColor.black.setFill(); NSColor.black.setStroke(); path.fill(); path.stroke()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        return true
    }
    img.isTemplate = false
    return img
}
