import Foundation

/// Maps a history to 0...1 over its own recent range, so a graph always shows detail: a 2% GPU spike
/// and a steady 68% memory line are not squashed against an absolute 0...100% scale.
/// - Headroom: the range is widened by `headroom` (10%) of the data range above and below, and by at
///   least `padding`, so a spike never touches the top edge and looks like it is hitting a maximum.
/// - `minSpan` keeps tiny wobbles from being blown up into noise: a flat line stays flat, centred.
/// - `floor` stops the range going below a natural minimum (a load or speed cannot be negative).
public func zoomed(_ values: [Double], minSpan: Double, floor: Double? = nil, padding: Double = 0,
                   headroom: Double = 0.10) -> [Double] {
    guard let hi = values.max(), let lo = values.min() else { return [] }
    let margin = max(padding, headroom * (hi - lo))
    var bottom = lo - margin
    var top = hi + margin
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

/// Hover scrubbing: which sample of a history is under the pointer. Samples are drawn right-aligned,
/// `slots` points wide in total, so a short history only covers the right edge. Nil when the pointer
/// is left of the first sample or there is no history.
public func scrubIndex(x: Double, width: Double, count: Int, slots: Int) -> Int? {
    guard count > 0, slots > 1, width > 0 else { return nil }
    let step = width / Double(slots - 1)
    let startX = width - step * Double(count - 1)
    guard x >= startX - step / 2 else { return nil }
    return min(count - 1, max(0, Int(((x - startX) / step).rounded())))
}

/// "now", "12 s ago", "1 min 5 s ago" for a sample that is `samplesAgo` samples old.
public func agoText(samplesAgo: Int, secondsPerSample: Double) -> String {
    let seconds = Int((Double(samplesAgo) * secondsPerSample).rounded())
    if seconds <= 0 { return "now" }
    if seconds < 60 { return "\(seconds) s ago" }
    let rest = seconds % 60
    return rest == 0 ? "\(seconds / 60) min ago" : "\(seconds / 60) min \(rest) s ago"
}
