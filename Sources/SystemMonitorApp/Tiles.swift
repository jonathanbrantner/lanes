import SwiftUI

/// What one tile on the main panel shows. Built by PanelView from the live data.
struct TileData: Identifiable {
    let id: MonitorItem
    let symbol: String
    let name: String
    let color: Color
    let big: String
    let small: String
    /// For drives: read and write speeds, drawn with the menu bar's blue down and orange up arrows.
    var rates: (read: String, write: String)?
    /// Top right corner: a temperature, or a warning such as memory pressure.
    var corner: String?
    var cornerColor: Color = .red
    /// Right of the drive speeds when there is room, e.g. "412 GB free".
    var footnote: String?
    /// 0...1 values for the little graph.
    let history: [Double]
}

/// One tile: name and corner text, a big number, a small caption and a little graph.
/// Clicking it opens that item's full section.
struct Tile: View {
    let data: TileData
    /// Nil for tiles that have nothing more to show.
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: data.symbol).font(.system(size: 11)).foregroundStyle(data.color)
                Text(data.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                if let corner = data.corner {
                    Text(corner).font(.system(size: 10, design: .monospaced)).foregroundStyle(data.cornerColor)
                }
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            Text(data.big).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let rates = data.rates {
                let speeds = HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text("↓").foregroundStyle(Color(nsColor: .systemBlue))
                        Text(rates.read).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        Text("↑").foregroundStyle(Color(nsColor: .systemOrange))
                        Text(rates.write).foregroundStyle(.secondary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        speeds
                        if let footnote = data.footnote { Spacer(minLength: 2); Text(footnote).foregroundStyle(.tertiary) }
                    }
                    speeds
                }
                .font(.system(size: 10, weight: .medium)).lineLimit(1)
            } else {
                Text(data.small).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            HistoryChart(values: data.history, color: data.color).frame(height: 28)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A small box for one core or one sensor: its name, its value and its own little graph.
struct MiniBox: View {
    let title: String
    let value: String
    let history: [Double]
    let color: Color
    /// Hover readout; set for boxes on an expanded page.
    var scrub: ScrubReadout?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(title).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
            HistoryChart(values: history, color: color, scrub: scrub).frame(height: 22)
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
