import AppKit

/// One line of a two-row cell: a coloured symbol (e.g. an arrow) followed by text.
struct IconRow {
    let symbol: String
    let symbolColor: NSColor
    let text: String
}

/// One block in the menu bar icon.
struct IconCell {
    enum Layout {
        case labeled(label: String, value: String)   // tiny coloured label above a bigger value
        case twoRows(top: IconRow, bottom: IconRow)  // two equal lines (e.g. read / write)
        case icon(symbol: String, symbolColor: NSColor, value: String)  // coloured symbol, then the value
        case meter(fraction: Double, meterColor: NSColor, value: String) // small vertical meter, then the value
    }
    let layout: Layout
    let color: NSColor                 // value text colour
    /// Strings used to reserve a fixed width, so the icon doesn't jitter as numbers change.
    let widthSamples: [String]
    var labelColor: NSColor = .secondaryLabelColor
    /// Icons style: a symbol drawn to the left of a two-row cell (the drive arrows).
    var leadingSymbol: (name: String, color: NSColor)?
    /// Icons style: text drawn right after the value in its own colour (the red temperature).
    var accent: (text: String, color: NSColor)?
    /// Names style, two-row cells: a small coloured name to the left of the rows (SSD, DISK).
    var leadingLabel: (text: String, color: NSColor)?
    /// Names style: a temperature drawn on the label line, after the name ("DISK  31°").
    var labelAccent: (text: String, color: NSColor)?
    /// Draw the accent before the value instead of after it.
    var accentFirst = false

    var isIconStyle: Bool {
        if case .icon = layout { return true }
        if case .meter = layout { return true }
        return leadingSymbol != nil
    }
}

/// Draws the menu bar icon as real readable values, not abstract bars.
enum IconRenderer {
    private static let height: CGFloat = 22
    private static let gap: CGFloat = 9
    private static let tightGap: CGFloat = 6
    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

    // The icon is redrawn only when its content changes (idle drives often show the same text).
    private static var cachedKey = ""
    private static var cachedImage: NSImage?

    static func image(cells: [IconCell]) -> NSImage {
        // Nothing selected in settings: show a small placeholder so the item stays clickable.
        let cells = cells.isEmpty
            ? [IconCell(layout: .labeled(label: "", value: "Lanes"), color: .labelColor, widthSamples: ["Lanes"])]
            : cells

        let key = cells.map { "\($0.layout)|\($0.color)|\($0.labelColor)|\($0.leadingSymbol?.name ?? "")|\($0.leadingLabel?.text ?? "")|\($0.labelAccent?.text ?? "")|\($0.accent?.text ?? "")|\($0.accentFirst)|\($0.accent?.color ?? .clear)" }.joined(separator: ";")
        if key == cachedKey, let cachedImage { return cachedImage }
        let image = render(cells)
        cachedKey = key
        cachedImage = image
        return image
    }

    private static func render(_ cells: [IconCell]) -> NSImage {
        let widths = stickyWidths(cells)
        // Icons style sits tighter: the symbol already separates the cells.
        let gap = cells.contains(where: \.isIconStyle) ? Self.tightGap : Self.gap
        let total = widths.reduce(0, +) + gap * CGFloat(cells.count - 1) + 4

        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 2
            for (cell, w) in zip(cells, widths) {
                draw(cell, x: x, width: w)
                x += w + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Steady width

    // A cell never gets narrower just because its numbers got shorter: the whole strip would shift
    // every time a digit changes, which is distracting. A cell shrinks only after it has been
    // narrower for a long while (a one-off "999 MB/s" spike should not widen the bar for good).
    private static var sticky: [String: (width: CGFloat, calm: Int)] = [:]
    private static let calmTicks = 120

    private static func identity(_ cell: IconCell) -> String {
        let base: String
        switch cell.layout {
        case .labeled(let label, _): base = "L\(label)"
        case .icon(let symbol, _, _): base = "I\(symbol)"
        case .meter(_, _, let value): base = "M\(value.contains("GB") ? "gb" : "pct")"
        case .twoRows: base = "R\(cell.leadingSymbol?.name ?? cell.leadingLabel?.text ?? "")"
        }
        return base + (cell.accent == nil ? "" : "+")
    }

    private static func stickyWidths(_ cells: [IconCell]) -> [CGFloat] {
        let ids = cells.map(identity)
        if Set(ids) != Set(sticky.keys) { sticky = [:] }   // items or style changed: start fresh
        return zip(cells, ids).map { cell, id in
            let now = width(of: cell)
            var entry = sticky[id] ?? (now, 0)
            if now > entry.width { entry = (now, 0) }
            else if now < entry.width {
                entry.calm += 1
                if entry.calm >= calmTicks { entry = (now, 0) }
            } else { entry.calm = 0 }
            sticky[id] = entry
            return entry.width
        }
    }

    private static func width(of cell: IconCell) -> CGFloat {
        let font: NSFont
        switch cell.layout {
        case .labeled: font = valueFont
        case .twoRows: font = rowFont
        case .icon, .meter: font = valueFont
        }
        var w = cell.widthSamples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        if case .labeled(let label, let value) = cell.layout {
            w = max(w, labelText(cell, label).size().width, valueText(cell, value).size().width)
        }
        if case .meter(_, _, let value) = cell.layout {
            w = max(w, valueText(cell, value).size().width)
            w += meterWidth + iconGap
        }
        if case .icon(_, _, let value) = cell.layout {
            w = max(w, valueText(cell, value).size().width)
            w += iconWidth + iconGap
        }
        if cell.leadingSymbol != nil { w += iconWidth + iconGap }
        if let label = cell.leadingLabel {
            w += (label.text as NSString).size(withAttributes: [.font: labelFont]).width + iconGap
        }
        if case .twoRows = cell.layout, let accent = cell.accent {
            w += iconGap + valueText(cell, "").size().width   // temperature right after the rows
            _ = accent
        }
        return ceil(w)
    }

    /// The small name above the value, with an optional red temperature after it.
    private static func labelText(_ cell: IconCell, _ label: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: label,
                                               attributes: [.font: labelFont, .foregroundColor: cell.labelColor])
        if let accent = cell.labelAccent {
            result.append(NSAttributedString(string: "  " + accent.text,
                                             attributes: [.font: labelFont, .foregroundColor: accent.color]))
        }
        return result
    }

    /// The value, with the accent (a red temperature) before or after it.
    private static func valueText(_ cell: IconCell, _ value: String) -> NSAttributedString {
        let coloured = NSMutableAttributedString(string: value, attributes: [.font: valueFont, .foregroundColor: cell.color])
        // Read and write arrows keep the blue and orange used everywhere else.
        for (arrow, color) in [("↓", NSColor.systemBlue), ("↑", NSColor.systemOrange)] {
            let range = (value as NSString).range(of: arrow)
            if range.location != NSNotFound { coloured.addAttribute(.foregroundColor, value: color, range: range) }
        }
        let main = coloured
        guard let accent = cell.accent else { return main }
        let extra = NSAttributedString(string: accent.text,
                                       attributes: [.font: valueFont, .foregroundColor: accent.color])
        let result = NSMutableAttributedString()
        if cell.accentFirst { result.append(extra); result.append(main) } else { result.append(main); result.append(extra) }
        return result
    }

    /// A coloured SF Symbol centred in the icon column at `x`.
    private static func drawSymbol(_ name: String, color: NSColor, x: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: x + (iconWidth - size.width) / 2, y: (height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    private static let meterWidth: CGFloat = 6
    private static let meterHeight: CGFloat = 16
    private static let iconWidth: CGFloat = 15
    private static let iconGap: CGFloat = 3

    private static func draw(_ cell: IconCell, x: CGFloat, width: CGFloat) {
        switch cell.layout {
        case .labeled(let label, let value):
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: cell.labelColor]
            let valueText = valueText(cell, value)
            _ = labelAttrs
            if !label.isEmpty {
                let text = labelText(cell, label)
                text.draw(at: NSPoint(x: x + (width - text.size().width) / 2, y: 14))
            }
            let s = valueText.size()
            valueText.draw(at: NSPoint(x: x + (width - s.width) / 2, y: label.isEmpty ? 4 : 1))
        case .meter(let fraction, let meterColor, let value):
            let text = valueText(cell, value)
            text.draw(at: NSPoint(x: x + meterWidth + iconGap, y: (height - text.size().height) / 2))
            let track = NSRect(x: x, y: (height - meterHeight) / 2, width: meterWidth, height: meterHeight)
            NSColor.labelColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            var fill = track
            fill.size.height = max(2, meterHeight * CGFloat(min(max(fraction, 0), 1)))
            meterColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        case .icon(let symbol, let symbolColor, let value):
            let text = valueText(cell, value)
            // Right after the symbol, so a short value never leaves a hole between them.
            text.draw(at: NSPoint(x: x + iconWidth + iconGap, y: (height - text.size().height) / 2))
            drawSymbol(symbol, color: symbolColor, x: x)
        case .twoRows(let top, let bottom):
            // Centre the ink inside the reserved width, so the icon's visual middle matches its
            // geometric middle (and the popover arrow) even when the numbers are short.
            let topString = rowString(top, textColor: cell.color)
            let bottomString = rowString(bottom, textColor: cell.color)
            let inkWidth = max(topString.size().width, bottomString.size().width)
            var x = x, width = width
            if let lead = cell.leadingSymbol {
                drawSymbol(lead.name, color: lead.color, x: x)
                x += iconWidth + iconGap
                width -= iconWidth + iconGap
            }
            if let label = cell.leadingLabel {
                let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: label.color]
                let size = (label.text as NSString).size(withAttributes: attrs)
                (label.text as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attrs)
                x += size.width + iconGap
                width -= size.width + iconGap
            }
            if cell.accent != nil {
                // Temperature right after the rows (not at the far edge), so there is no hole.
                let accentText = valueText(cell, "")
                let used = max(inkWidth, rowSampleWidth(cell))
                accentText.draw(at: NSPoint(x: x + used + iconGap, y: (height - accentText.size().height) / 2))
                topString.draw(at: NSPoint(x: x, y: 11.5))
                bottomString.draw(at: NSPoint(x: x, y: 0.5))
                return
            }
            let inset = max(0, (width - inkWidth) / 2)
            topString.draw(at: NSPoint(x: x + inset, y: 11.5))
            bottomString.draw(at: NSPoint(x: x + inset, y: 0.5))
        }
    }

    /// Width reserved for the read / write rows (the widest sample).
    private static func rowSampleWidth(_ cell: IconCell) -> CGFloat {
        cell.widthSamples.map { ($0 as NSString).size(withAttributes: [.font: rowFont]).width }.max() ?? 0
    }

    private static func rowString(_ row: IconRow, textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: row.symbol + " ",
                                               attributes: [.font: rowFont, .foregroundColor: row.symbolColor])
        result.append(NSAttributedString(string: row.text,
                                         attributes: [.font: rowFont, .foregroundColor: textColor]))
        return result
    }
}
