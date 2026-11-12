// DrawingReadTools: read_drawing, list_drawing_entities, list_drawing_dimensions (#260). Read-only
// tools over OCCTSwiftIO's drawing import. They return coordinates, counts and values, never
// images, and never touch the scene or the manifest: a drawing is a file the agent reads, not a
// body. `measure_drawing` is in DrawingMeasureTool.swift.

import Foundation
import MCP
import OCCTSwiftIO

public enum DrawingReadTools {

    // ── records ─────────────────────────────────────────────────────────

    struct Box: Encodable {
        let min: [Double]
        let max: [Double]

        init(_ bounds: DrawingEntities.Bounds) {
            min = DrawingEntities.xyz(bounds.min)
            max = DrawingEntities.xyz(bounds.max)
        }

        init(min: DXF.Point, max: DXF.Point) {
            self.min = DrawingEntities.xyz(min)
            self.max = DrawingEntities.xyz(max)
        }
    }

    struct DefinitionPoint: Encodable {
        /// The DXF group code of the point's x value (10, 13, 14, 15 or 16).
        let group: Int
        /// What the point is, where SwiftDXF documents it for this kind; nil otherwise.
        let role: String?
        let point: [Double]
    }

    struct DimensionRecord: Encodable {
        let id: String
        /// `linear`, `aligned`, `angular`, `diameter`, `radius`, `angular3Point`, `ordinate` or
        /// `unknown(n)`.
        let kind: String
        /// `length` for every kind but the two angular ones.
        let valueKind: String
        /// The stored measurement (DXF group 42), nil when the file omits it.
        let value: Double?
        /// `drawing units` for a length.
        ///
        /// An angle's unit is not declared in the file.
        let valueUnit: String
        let valueMm: Double?
        /// The length between the dimension's own definition points, for an aligned, radius or
        /// diameter dimension; nil for the other kinds.
        ///
        /// It is a check on `value` (a stale or overridden dimension disagrees with its geometry)
        /// and the only value when the file omits group 42, which ezdxf says is common.
        let valueFromPoints: Double?
        let valueFromPointsMm: Double?
        /// The user's text override; nil when the dimension shows its own value.
        let text: String?
        let textPosition: [Double]
        let definitionPoints: [DefinitionPoint]
        let layer: String
        let color: Int
    }

    struct EntityRecord: Encodable {
        let id: String
        let type: String
        /// Absent for an entity this build has no mapping for.
        let layer: String?
        let color: Int?
        let bounds: Box?
        var start: [Double]?
        var end: [Double]?
        var center: [Double]?
        var at: [Double]?
        var majorAxis: [Double]?
        var radius: Double?
        var length: Double?
        var startAngleDeg: Double?
        var endAngleDeg: Double?
        var sweepDeg: Double?
        var ratio: Double?
        var startParam: Double?
        var endParam: Double?
        var height: Double?
        var rotationDeg: Double?
        var text: String?
        var vertices: [[Double]]?
        /// The bulge of the segment leaving each vertex; present only when some segment is curved.
        var bulges: [Double]?
        var closed: Bool?
        var dimension: DimensionRecord?
    }

    static func dimensionRecord(
        _ d: DXF.Dimension, id: String, mmPerUnit: Double?
    ) -> DimensionRecord {
        let kind: String
        switch d.kind {
        case .linear: kind = "linear"
        case .aligned: kind = "aligned"
        case .angular: kind = "angular"
        case .diameter: kind = "diameter"
        case .radius: kind = "radius"
        case .angular3Point: kind = "angular3Point"
        case .ordinate: kind = "ordinate"
        case .unknown(let n): kind = "unknown(\(n))"
        }
        let isAngle = d.kind == .angular || d.kind == .angular3Point
        var points: [DefinitionPoint] = []
        // SwiftDXF documents the roles for linear, aligned, radius and diameter dimensions.
        let roles: (p10: String?, p13: String?, p14: String?, p15: String?)
        switch d.kind {
        case .linear, .aligned:
            roles = ("dimensionLine", "extensionLine1Origin", "extensionLine2Origin", nil)
        case .radius, .diameter:
            roles = ("measuredFrom", nil, nil, "measuredTo")
        default:
            roles = (nil, nil, nil, nil)
        }
        points.append(.init(group: 10, role: roles.p10, point: DrawingEntities.xyz(d.defPoint)))
        if let p = d.defPoint2 {
            points.append(.init(group: 13, role: roles.p13, point: DrawingEntities.xyz(p)))
        }
        if let p = d.defPoint3 {
            points.append(.init(group: 14, role: roles.p14, point: DrawingEntities.xyz(p)))
        }
        if let p = d.defPoint4 {
            points.append(.init(group: 15, role: roles.p15, point: DrawingEntities.xyz(p)))
        }
        if let p = d.defPoint5 {
            points.append(
                .init(group: 16, role: "dimensionArcLocation", point: DrawingEntities.xyz(p)))
        }
        var fromPoints: Double?
        switch d.kind {
        case .aligned:
            if let a = d.defPoint2, let b = d.defPoint3 {
                fromPoints = DrawingEntities.distance(a, b)
            }
        case .radius, .diameter:
            if let b = d.defPoint4 { fromPoints = DrawingEntities.distance(d.defPoint, b) }
        default:
            break
        }
        return DimensionRecord(
            id: id, kind: kind, valueKind: isAngle ? "angle" : "length", value: d.measurement,
            valueUnit: isAngle ? "as stored, not declared by DXF" : "drawing units",
            valueMm: isAngle ? nil : d.measurement.flatMap { v in mmPerUnit.map { v * $0 } },
            valueFromPoints: fromPoints,
            valueFromPointsMm: fromPoints.flatMap { v in mmPerUnit.map { v * $0 } },
            // A text of exactly `<>` is DXF's "show the measured value": no override.
            text: d.textOverride == "<>" ? nil : d.textOverride,
            textPosition: DrawingEntities.xyz(d.textPosition),
            definitionPoints: points, layer: d.layer, color: d.color)
    }

    static func entityRecord(_ entity: DXF.Entity, index: Int, mmPerUnit: Double?) -> EntityRecord {
        let id = DrawingEntities.id(index)
        var record = EntityRecord(
            id: id, type: DrawingEntities.typeName(entity), layer: DrawingEntities.layer(entity),
            color: DrawingEntities.color(entity),
            bounds: DrawingEntities.bounds(of: entity).map(Box.init))
        switch entity {
        case .line(let a, let b, _, _):
            record.start = DrawingEntities.xyz(a)
            record.end = DrawingEntities.xyz(b)
            record.length = DrawingEntities.distance(a, b)
        case .circle(let c, let r, _, _):
            record.center = DrawingEntities.xyz(c)
            record.radius = r
        case .arc(let c, let r, let startDeg, let endDeg, _, _):
            let sweep = DrawingEntities.sweepDeg(startDeg: startDeg, endDeg: endDeg)
            let s = startDeg * .pi / 180
            let e = s + sweep * .pi / 180
            record.center = DrawingEntities.xyz(c)
            record.radius = r
            record.startAngleDeg = startDeg
            record.endAngleDeg = endDeg
            record.sweepDeg = sweep
            record.start = [c.x + r * cos(s), c.y + r * sin(s), c.z]
            record.end = [c.x + r * cos(e), c.y + r * sin(e), c.z]
            record.length = r * sweep * .pi / 180
        case .ellipse(let c, let m, let ratio, let startParam, let endParam, _, _):
            record.center = DrawingEntities.xyz(c)
            record.majorAxis = DrawingEntities.xyz(m)
            record.ratio = ratio
            record.startParam = startParam
            record.endParam = endParam
        case .point(let p, _, _):
            record.at = DrawingEntities.xyz(p)
        case .text(let p, let height, let rotation, let string, _, _):
            record.at = DrawingEntities.xyz(p)
            record.height = height
            record.rotationDeg = rotation
            record.text = string
        case .polyline(let vertices, let closed, _, _):
            record.vertices = vertices.map { DrawingEntities.xyz($0.point) }
            if vertices.contains(where: { $0.bulge != 0 }) {
                record.bulges = vertices.map(\.bulge)
            }
            record.closed = closed
            record.length = DrawingEntities.polylineLength(vertices, closed: closed)
        case .dimension(let d):
            record.dimension = dimensionRecord(d, id: id, mmPerUnit: mmPerUnit)
        @unknown default:
            break
        }
        return record
    }

    // ── shared argument handling ────────────────────────────────────────

    /// JSON for a result.
    ///
    /// A number that is not finite (a `1e999` or `nan` in the file) is written as the string
    /// `"inf"`, `"-inf"` or `"nan"`, rather than failing the whole result.
    static func encode<T: Encodable>(_ value: T) -> ToolText {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            return .init(String(decoding: try encoder.encode(value), as: UTF8.self))
        } catch {
            return .init("Failed to encode result: \(error.localizedDescription)", isError: true)
        }
    }

    /// A bad argument, named.
    struct ArgumentError: Error, CustomStringConvertible {
        let description: String
    }

    /// The argument, or nil when it is absent or JSON `null`.
    ///
    /// `Value` is `ExpressibleByNilLiteral`, so a bare `nil` in a ternary would be `.null`, not none.
    static func present(_ value: Value?) -> Value? {
        guard let value, value != .null else { return nil }
        return value
    }

    /// An optional integer; absent and JSON `null` are nil, anything else that is not one is an error.
    static func optionalInt(
        _ value: Value?, name: String, in range: ClosedRange<Int> = Int.min...Int.max
    ) throws -> Int? {
        guard let value = present(value) else { return nil }
        guard let int = value.intValue else {
            throw ArgumentError(description: "`\(name)` must be an integer.")
        }
        guard range.contains(int) else {
            let bounds =
                range.upperBound == Int.max
                ? "at least \(range.lowerBound)" : "from \(range.lowerBound) to \(range.upperBound)"
            throw ArgumentError(description: "`\(name)` must be \(bounds).")
        }
        return int
    }

    /// Refuse an argument name the tool does not take, so a misspelt filter is not an ignored one.
    static func rejectUnknownArguments(
        _ arguments: [String: Value], allowed: [String], tool: String
    ) throws {
        let unknown = arguments.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ArgumentError(
                description:
                    "\(tool) takes no argument named \(unknown.map { "`\($0)`" }.joined(separator: ", ")). "
                    + "Arguments: \(allowed.joined(separator: ", ")).")
        }
    }

    /// An optional finite number, with the same absent and `null` rule.
    static func optionalNumber(_ value: Value?, name: String) throws -> Double? {
        guard let value = present(value) else { return nil }
        guard let number = value.numberValue, number.isFinite else {
            throw ArgumentError(description: "`\(name)` must be a number.")
        }
        return number
    }

    /// An optional string, with the same absent and `null` rule.
    static func optionalString(_ value: Value?, name: String) throws -> String? {
        guard let value = present(value) else { return nil }
        guard let string = value.stringValue else {
            throw ArgumentError(description: "`\(name)` must be a string.")
        }
        return string
    }

    /// An optional array of strings; absent and JSON `null` are nil, anything else is an error.
    static func stringList(_ value: Value?, name: String) throws -> [String]? {
        guard let value, value != .null else { return nil }
        guard let array = value.arrayValue else {
            throw ArgumentError(description: "`\(name)` must be an array of strings.")
        }
        let strings = array.compactMap { $0.stringValue }
        guard strings.count == array.count else {
            throw ArgumentError(description: "`\(name)` must be an array of strings.")
        }
        return strings
    }

    /// An optional array of numbers; absent and JSON `null` are nil, anything else is an error.
    static func numberList(_ value: Value?, name: String) throws -> [Double]? {
        guard let value, value != .null else { return nil }
        guard let array = value.arrayValue else {
            throw ArgumentError(
                description: "`\(name)` must be [xmin, ymin, xmax, ymax], an array of four numbers."
            )
        }
        let numbers = array.compactMap { $0.numberValue }
        guard numbers.count == array.count else {
            throw ArgumentError(
                description: "`\(name)` must be [xmin, ymin, xmax, ymax], an array of four numbers."
            )
        }
        return numbers
    }

    /// The dimension kinds `list_drawing_dimensions` filters on.
    static let dimensionKinds = [
        "linear", "aligned", "angular", "diameter", "radius", "angular3Point", "ordinate",
    ]

    /// The file reference every drawing tool carries, so a result says which file it read.
    struct SourceRef: Encodable {
        let fileName: String
        let sha256: String
    }

    static func sourceRef(_ loaded: LoadedDrawing) -> SourceRef {
        SourceRef(fileName: loaded.source.fileName, sha256: loaded.source.sha256)
    }

    /// A drawing read, or the error result that says why it was not.
    enum DrawingLoad {
        case loaded(LoadedDrawing)
        case failed(ToolText)
    }

    static func load(_ inputPath: String) async -> DrawingLoad {
        do {
            return .loaded(try await DrawingFile.load(path: inputPath))
        } catch {
            return .failed(ToolText("\(error)", isError: true))
        }
    }

    static func page(offset: Int?, limit: Int?, maxLimit: Int, defaultLimit: Int) -> (
        offset: Int, limit: Int
    ) {
        (
            max(0, offset ?? 0),
            min(maxLimit, max(1, limit ?? defaultLimit))
        )
    }

    // ── read_drawing ────────────────────────────────────────────────────

    struct LayerSummary: Encodable {
        let name: String
        let total: Int
        let byType: [String: Int]
    }

    struct UnitsRecord: Encodable {
        /// The raw `$INSUNITS` code, nil when the header does not declare one.
        let insUnits: Int?
        let name: String
        /// Nil when the file is unitless or declares nothing, so no millimetre figure is given.
        let mmPerUnit: Double?
    }

    struct ExtentsRecord: Encodable {
        /// `$EXTMIN` / `$EXTMAX` from the header, which an editor may leave stale.
        let declared: Box?
        /// The union of the entities' own bounds, as read.
        let computed: Box?
    }

    struct DrawingReport: Encodable {
        let source: LoadedDrawing.Source
        let units: UnitsRecord
        let extents: ExtentsRecord
        let entityCount: Int
        let byType: [String: Int]
        let layers: [LayerSummary]
        /// Entities in the file that the reader does not model, by type and layer.
        let skipped: LoadedDrawing.Skipped
        let warnings: [String]
    }

    public static func readDrawing(inputPath: String) async -> ToolText {
        let loaded: LoadedDrawing
        switch await load(inputPath) {
        case .loaded(let value): loaded = value
        case .failed(let failure): return failure
        }
        let drawing = loaded.drawing
        var byType: [String: Int] = [:]
        var byLayer: [String: [String: Int]] = [:]
        var union: DrawingEntities.Bounds?
        for entity in drawing.entities {
            let type = DrawingEntities.typeName(entity)
            byType[type, default: 0] += 1
            if let layer = DrawingEntities.layer(entity) {
                byLayer[layer, default: [:]][type, default: 0] += 1
            }
            if let box = DrawingEntities.bounds(of: entity) {
                if union == nil {
                    union = box
                } else {
                    union?.include(box.min)
                    union?.include(box.max)
                }
            }
        }
        let layers = byLayer.keys.sorted().map { name in
            LayerSummary(
                name: name, total: byLayer[name]?.values.reduce(0, +) ?? 0,
                byType: byLayer[name] ?? [:])
        }

        var warnings: [String] = []
        if drawing.entities.isEmpty {
            warnings.append("The drawing has no entities the reader models.")
        }
        if loaded.mmPerUnit == nil {
            warnings.append(
                "The drawing declares no usable units ($INSUNITS is \(DrawingUnits.name(insUnits: drawing.insUnits))), "
                    + "so no millimetre figure is given. measure_drawing takes `mmPerUnit` to supply one."
            )
        }
        if let other = byType["other"], other > 0 {
            warnings.append(
                "\(other) entity(ies) are of a type this server has no mapping for and are listed as "
                    + "type `other`, with no layer, colour or geometry.")
        }
        if let inserts = loaded.skipped.byType["INSERT"], inserts > 0 {
            warnings.append(
                "\(inserts) block insert(s) are not expanded, so the geometry they place is missing "
                    + "from the entity list.")
        }
        if loaded.skipped.total > 0 {
            warnings.append(
                "\(loaded.skipped.total) entity record(s) were skipped; see `skipped`.")
        }

        let declared: Box? = {
            guard let lo = drawing.extMin, let hi = drawing.extMax else { return nil }
            return Box(min: lo, max: hi)
        }()
        return encode(
            DrawingReport(
                source: loaded.source,
                units: UnitsRecord(
                    insUnits: drawing.insUnits, name: DrawingUnits.name(insUnits: drawing.insUnits),
                    mmPerUnit: loaded.mmPerUnit),
                extents: ExtentsRecord(declared: declared, computed: union.map(Box.init)),
                entityCount: drawing.entities.count, byType: byType, layers: layers,
                skipped: loaded.skipped, warnings: warnings))
    }

    // ── list_drawing_entities ───────────────────────────────────────────

    struct EntityListing: Encodable {
        let source: SourceRef
        /// Entities matching the filters, before paging.
        let total: Int
        let offset: Int
        let returned: Int
        let truncated: Bool
        let unit: String
        let entities: [EntityRecord]
    }

    public static func listDrawingEntities(
        inputPath: String, types: [String]?, layers: [String]?, rect: [Double]?,
        rectMode: String?, limit: Int?, offset: Int?
    ) async -> ToolText {
        if let types {
            let unknown = types.filter { !DrawingEntities.typeNames.contains($0) }
            if !unknown.isEmpty {
                return .init(
                    "Unknown entity type(s) \(unknown.joined(separator: ", ")). "
                        + "Types: \(DrawingEntities.typeNames.joined(separator: ", ")).",
                    isError: true)
            }
        }
        var window: (xmin: Double, ymin: Double, xmax: Double, ymax: Double)?
        if let rect {
            guard rect.count == 4, rect[0] <= rect[2], rect[1] <= rect[3] else {
                return .init(
                    "`rect` must be [xmin, ymin, xmax, ymax] with min <= max, in drawing units.",
                    isError: true)
            }
            window = (rect[0], rect[1], rect[2], rect[3])
        }
        let mode = rectMode ?? "intersects"
        guard mode == "intersects" || mode == "within" else {
            return .init("`rectMode` must be \"intersects\" or \"within\".", isError: true)
        }
        let loaded: LoadedDrawing
        switch await load(inputPath) {
        case .loaded(let value): loaded = value
        case .failed(let failure): return failure
        }

        let typeSet = types.map(Set.init)
        let layerSet = layers.map(Set.init)
        var matching: [Int] = []
        for (index, entity) in loaded.drawing.entities.enumerated() {
            if let typeSet, !typeSet.contains(DrawingEntities.typeName(entity)) { continue }
            if let layerSet {
                guard let layer = DrawingEntities.layer(entity), layerSet.contains(layer) else {
                    continue
                }
            }
            if let window {
                guard let box = DrawingEntities.bounds(of: entity) else { continue }
                let hit =
                    mode == "within"
                    ? box.within(
                        xmin: window.xmin, ymin: window.ymin, xmax: window.xmax, ymax: window.ymax)
                    : box.intersects(
                        xmin: window.xmin, ymin: window.ymin, xmax: window.xmax, ymax: window.ymax)
                if !hit { continue }
            }
            matching.append(index)
        }
        let paging = page(offset: offset, limit: limit, maxLimit: 5000, defaultLimit: 200)
        let slice = matching.dropFirst(paging.offset).prefix(paging.limit)
        let records = slice.map {
            entityRecord(loaded.drawing.entities[$0], index: $0, mmPerUnit: loaded.mmPerUnit)
        }
        return encode(
            EntityListing(
                source: sourceRef(loaded), total: matching.count, offset: paging.offset,
                returned: records.count, truncated: paging.offset + records.count < matching.count,
                unit: "drawing units", entities: records))
    }

    // ── list_drawing_dimensions ─────────────────────────────────────────

    struct DimensionListing: Encodable {
        let source: SourceRef
        let total: Int
        let offset: Int
        let returned: Int
        let truncated: Bool
        let units: UnitsRecord
        let dimensions: [DimensionRecord]
    }

    public static func listDrawingDimensions(
        inputPath: String, layers: [String]?, kinds: [String]?, limit: Int?, offset: Int?
    ) async -> ToolText {
        if let unknown = kinds?.filter({ !dimensionKinds.contains($0) && !$0.hasPrefix("unknown(") }
        ),
            !unknown.isEmpty
        {
            return .init(
                "Unknown dimension kind(s) \(unknown.joined(separator: ", ")). "
                    + "Kinds: \(dimensionKinds.joined(separator: ", ")).",
                isError: true)
        }
        let loaded: LoadedDrawing
        switch await load(inputPath) {
        case .loaded(let value): loaded = value
        case .failed(let failure): return failure
        }
        let layerSet = layers.map(Set.init)
        let kindSet = kinds.map(Set.init)
        var all: [DimensionRecord] = []
        for (index, entity) in loaded.drawing.entities.enumerated() {
            guard case .dimension(let d) = entity else { continue }
            let record = dimensionRecord(
                d, id: DrawingEntities.id(index), mmPerUnit: loaded.mmPerUnit)
            if let layerSet, !layerSet.contains(record.layer) { continue }
            if let kindSet, !kindSet.contains(record.kind) { continue }
            all.append(record)
        }
        let paging = page(offset: offset, limit: limit, maxLimit: 5000, defaultLimit: 500)
        let slice = Array(all.dropFirst(paging.offset).prefix(paging.limit))
        return encode(
            DimensionListing(
                source: sourceRef(loaded), total: all.count, offset: paging.offset,
                returned: slice.count, truncated: paging.offset + slice.count < all.count,
                units: UnitsRecord(
                    insUnits: loaded.drawing.insUnits,
                    name: DrawingUnits.name(insUnits: loaded.drawing.insUnits),
                    mmPerUnit: loaded.mmPerUnit),
                dimensions: slice))
    }
}
