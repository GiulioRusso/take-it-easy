import Foundation

/// Pure angle math for the radial wheel. Angles are degrees clockwise from the top (12 o'clock).
nonisolated enum WheelGeometry {
    static let deadZone = 34.0      // center = cancel
    static let ringOuter = 112.0
    static let subInner = 118.0
    static let subOuter = 176.0
    static let childStep = 38.0     // angular width of each sub-ring item

    static func normalize(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Smallest absolute difference between two angles.
    static func distance(_ a: Double, _ b: Double) -> Double {
        abs(normalize(a - b + 180) - 180)
    }

    /// Angle of a vector in y-up coordinates (AppKit screen space).
    static func angle(dx: Double, dy: Double) -> Double {
        normalize(90 - atan2(dy, dx) * 180 / .pi)
    }

    static func sliceAngle(_ index: Int, count: Int) -> Double {
        Double(index) * 360 / Double(count)
    }

    /// Slice whose center is nearest to `angle`; slice 0 is centered at the top.
    static func slice(at angle: Double, count: Int) -> Int {
        let step = 360 / Double(count)
        return Int(normalize(angle + step / 2) / step) % count
    }

    static func childAngle(_ index: Int, count: Int, parent: Double) -> Double {
        normalize(parent + (Double(index) - Double(count - 1) / 2) * childStep)
    }

    static func child(at angle: Double, count: Int, parent: Double) -> Int {
        (0..<count).min { distance(childAngle($0, count: count, parent: parent), angle)
                        < distance(childAngle($1, count: count, parent: parent), angle) } ?? 0
    }

    #if DEBUG
    static func selfCheck() {
        assert(angle(dx: 0, dy: 1) == 0)                       // up
        assert(abs(angle(dx: 1, dy: 0) - 90) < 1e-9)          // right
        assert(abs(angle(dx: 0, dy: -1) - 180) < 1e-9)        // down
        assert(abs(angle(dx: -1, dy: 0) - 270) < 1e-9)        // left
        assert(slice(at: 0, count: 6) == 0)
        assert(slice(at: 359, count: 6) == 0)                 // wraps around the top
        assert(slice(at: 29, count: 6) == 0)
        assert(slice(at: 31, count: 6) == 1)
        assert(slice(at: 180, count: 4) == 2)
        assert(distance(350, 10) == 20)
        assert(child(at: 90, count: 3, parent: 90) == 1)      // middle child sits on the parent
        assert(child(at: 50, count: 3, parent: 90) == 0)
        assert(child(at: 135, count: 3, parent: 90) == 2)
        assert(child(at: 0, count: 2, parent: 0) == 0 || child(at: 0, count: 2, parent: 0) == 1)
    }
    #endif
}
