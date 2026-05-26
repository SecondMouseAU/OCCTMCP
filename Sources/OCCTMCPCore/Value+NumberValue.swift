import MCP

extension Value {
    /// Back-port of the upstream `Value.numberValue` proposed in
    /// modelcontextprotocol/swift-sdk#225 (PR #226), pending a tagged
    /// release of the official SDK.
    ///
    /// JSON has a single `number` type with no integer/float distinction,
    /// and `Value.init(from:)` tries `Int` first — so `Value.double(0)`
    /// round-trips through JSON to `Value.int(0)` and `doubleValue` returns
    /// `nil`. This accessor coerces both `.int` and `.double` to `Double`,
    /// which is what tool-argument readers want for coordinates, dimensions,
    /// tolerances, and angles. Returns `nil` for any non-numeric case.
    ///
    /// Remove this file once the SDK ships `numberValue` upstream; no other
    /// code changes are required.
    var numberValue: Double? {
        switch self {
        case .int(let value):    return Double(value)
        case .double(let value): return value
        default:                 return nil
        }
    }
}
