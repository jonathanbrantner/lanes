import SwiftUI

/// What one tile on the main panel shows. Built by PanelView from the live data.
struct TileData: Identifiable {
    let id: MonitorItem
    let symbol: String
    let name: String
    let color: Color
    let big: String
    let small: String
    /// Top right corner: a temperature, or a warning such as memory pressure.
    var corner: String?
    var cornerColor: Color = .red
    /// 0...1 values for the little graph.
    let history: [Double]
}

/// One tile: name and corner text, a big number, a small caption and a little graph.
/// Clicking it opens that item's full section.
struct Tile: View {
    let data: TileData
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: data.symbol).font(.system(size: 11)).foregroundStyle(data.color)
                    Text(data.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    if let corner = data.corner {
                        Text(corner).font(.system(size: 10, design: .monospaced)).foregroundStyle(data.cornerColor)
                    }
                }
                Text(data.big).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(data.small).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                HistoryChart(values: data.history, color: data.color).frame(height: 22)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
