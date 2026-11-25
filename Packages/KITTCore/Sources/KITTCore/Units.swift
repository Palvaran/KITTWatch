import Foundation

// Explicit unit types. The app does the arithmetic; the model never does.
// Note: on the Series 5 (arm64_32) Swift's Int is 32 bits. Counts here are tiny,
// so Int is fine, but anything that can grow (file sizes, sequences) uses Int64.

public struct People: Hashable, Codable, Comparable, Sendable {
    public let count: Int
    public init(_ count: Int) {
        precondition(count >= 0, "People cannot be negative")
        self.count = count
    }
    public static func < (a: People, b: People) -> Bool { a.count < b.count }
    public var label: String { count == 1 ? "1 person" : "\(count) people" }
}

public struct Days: Hashable, Codable, Comparable, Sendable {
    public let count: Int
    public init(_ count: Int) {
        precondition(count >= 0, "Days cannot be negative")
        self.count = count
    }
    public static func < (a: Days, b: Days) -> Bool { a.count < b.count }
    public var label: String { count == 1 ? "1 day" : "\(count) days" }
}

/// US liquid gallons. Stored as Double so a user can say "two and a half gallons".
public struct USGallons: Hashable, Codable, Comparable, Sendable {
    public let value: Double
    public init(_ value: Double) { self.value = value }

    public static let zero = USGallons(0)
    public static func + (a: USGallons, b: USGallons) -> USGallons { USGallons(a.value + b.value) }
    public static func - (a: USGallons, b: USGallons) -> USGallons { USGallons(a.value - b.value) }
    public static func < (a: USGallons, b: USGallons) -> Bool { a.value < b.value }

    /// "9 gal", "2.5 gal". Never shows floating-point noise.
    public var label: String { "\(Self.format(value)) gal" }
    public var longLabel: String {
        let n = Self.format(value)
        return value == 1 ? "\(n) US gallon" : "\(n) US gallons"
    }

    static func format(_ v: Double) -> String {
        let rounded = (v * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}

/// A rate such as "1 gallon per person per day".
public struct GallonsPerPersonDay: Hashable, Codable, Sendable {
    public let value: Double
    public init(_ value: Double) { self.value = value }
    public var label: String { "\(USGallons.format(value)) gal per person per day" }

    public static func * (rate: GallonsPerPersonDay, pd: (People, Days)) -> USGallons {
        USGallons(rate.value * Double(pd.0.count) * Double(pd.1.count))
    }
}
