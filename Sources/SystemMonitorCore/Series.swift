import Foundation

/// Maps a history to 0...1 over its own recent range, so a graph always shows detail: a 2% GPU spike
/// and a steady 68% memory line are not squashed against an absolute 0...100% scale.
/// - `padding` adds room above the highest and below the lowest value, so the line never touches the edges.
/// - `minSpan` keeps tiny wobbles from being blown up into noise: a flat line stays flat, centred.
/// - `floor` stops the range going below a natural minimum (a load or speed cannot be negative).
public func zoomed(_ values: [Double], minSpan: Double, floor: Double? = nil, padding: Double = 0) -> [Double] {
    guard let hi = values.max(), let lo = values.min() else { return [] }
    var bottom = lo - padding
    var top = hi + padding
    if let floor, bottom < floor { bottom = floor }
    if top - bottom < minSpan {
        // Too flat: widen around the middle, but never below the floor (extend upwards instead).
        let extra = minSpan - (top - bottom)
        var newBottom = bottom - extra / 2
        var newTop = top + extra / 2
        if let floor, newBottom < floor {
            newTop += floor - newBottom
            newBottom = floor
        }
        bottom = newBottom
        top = newTop
    }
    return values.map { ($0 - bottom) / (top - bottom) }
}
