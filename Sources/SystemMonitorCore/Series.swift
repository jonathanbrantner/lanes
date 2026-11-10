import Foundation

/// Maps a history to 0...1 over its own recent range, so a graph always shows detail: a 5% CPU
/// line and a steady 68% memory line are not squashed against an absolute 0...100% scale.
/// `minSpan` keeps tiny wobbles from being blown up into noise: a flat line stays flat, centred.
/// `floor` stops the range going below a natural minimum (a load or speed cannot be negative).
public func zoomed(_ values: [Double], minSpan: Double, floor: Double? = nil) -> [Double] {
    guard let hi = values.max(), let lo = values.min() else { return [] }
    let span = max(hi - lo, minSpan)
    var bottom = (hi + lo) / 2 - span / 2          // centre the data in the range
    if let floor, bottom < floor { bottom = floor }
    return values.map { ($0 - bottom) / span }
}
