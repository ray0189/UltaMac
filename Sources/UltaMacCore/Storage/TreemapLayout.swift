import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
public enum TreemapLayout {
    /// Returns one rect per value, in the same order. Values should be sorted descending.
    public static func squarify(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = bounds
        var i = 0

        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard let mx = row.max(), let mn = row.min(), s > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }

        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [areas[i]]
            var j = i + 1
            while j < areas.count, worst(row + [areas[j]], side) <= worst(row, side) {
                row.append(areas[j]); j += 1
            }
            let rowSum = row.reduce(0, +)
            let thickness = CGFloat(rowSum / max(side, 0.0001))
            if remaining.width >= remaining.height {
                var y = remaining.minY
                for a in row {
                    let h = CGFloat(a) / thickness
                    result.append(CGRect(x: remaining.minX, y: y, width: thickness, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                var x = remaining.minX
                for a in row {
                    let w = CGFloat(a) / thickness
                    result.append(CGRect(x: x, y: remaining.minY, width: w, height: thickness))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            i = j
        }
        return result
    }
}
