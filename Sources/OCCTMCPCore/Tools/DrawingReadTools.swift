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
        /// The measurement the dimension's own geometry gives.
        ///
        /// This is SwiftDXF's `computedMeasurement`: the distance between the extension-line origins
        /// along the dimension's rotation for a linear one, between them for an aligned one,
        /// between the two ends of a radius or diameter. Nil for an angular or ordinate dimension.
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
        /// A linear dimension's measuring direction in degrees, absent when the file omits it,
        /// which means horizontal.
        let rotationDeg: Double?
        /// The oblique angle of the extension lines in degrees, absent when the file omits it.
        let obliqueAngleDeg: Double?
        /// The dimension style's name, absent when the file names none.
        let styleName: String?
        /// The DXF handle (group 5), absent when the file has none.
        ///
        /// It survives an edit that moves entities, which the id does not.
        let handle: String?
        /// Section and position, such as `ENTITIES:12`, present even when the file has no handles.
        let locator: String
        /// The block references an expanded dimension came through, outermost first; absent for one
        /// that is where the file put it.
        let via: [String]?
        /// The names of those blocks.
        let blocks: [String]?
        /// True for a dimension the reader rebuilt from loose pieces; absent for one the file
        /// stored as a dimension.
        ///
        /// Only a JWW has any: Jw_cad can keep a dimension as separate lines and text, and a JWW
        /// can also store a dimension record, which is not marked.
        var rebuilt: Bool?
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
        /// A spline's degree, flags and NURBS data as stored in the file.
        ///
        /// Control points, knots, weights and fit points are absent when the file has none (a
        /// fit-point spline has no control points, and a non-rational one has no weights).
        var degree: Int?
        var periodic: Bool?
        var rational: Bool?
        var controlPoints: [[Double]]?
        var knots: [Double]?
        var weights: [Double]?
        var fitPoints: [[Double]]?
        /// A hatch's pattern name (`SOLID`, `ANSI31`), whether it is a solid fill, and its boundaries.
        ///
        /// Only the boundary and the fill kind are read, not the hatch lines.
        var patternName: String?
        var solid: Bool?
        var boundaryPaths: [HatchPathRecord]?
        /// A leader's path is `vertices` from the arrowhead end; `splinePath` says it curves
        /// through them, and `annotationHandle` names the text or block it is attached to.
        var arrowhead: Bool?
        var splinePath: Bool?
        var annotationHandle: String?
        var styleName: String?
        var dimension: DimensionRecord?
        /// The DXF handle (group 5), absent when the file has none.
        ///
        /// It survives an edit that moves entities, which the id does not.
        var handle: String?
        /// Section and position, such as `ENTITIES:12`, present even when the file has no handles.
        var locator: String?
        /// The block references an expanded entity came through, outermost first, each a handle or
        /// a locator; absent for an entity that is where the file put it.
        var via: [String]?
        /// The names of those blocks.
        var blocks: [String]?
    }

    static func dimensionRecord(
        _ d: DXF.Dimension, id: String, mmPerUnit: Double?, identity: DXF.Identity,
        rebuilt: Bool
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
        let fromPoints = d.computedMeasurement
        return DimensionRecord(
            id: id, kind: kind, valueKind: isAngle ? "angle" : "length", value: d.measurement,
            valueUnit: isAngle ? "as stored, not declared by DXF" : "drawing units",
            valueMm: isAngle ? nil : d.measurement.flatMap { v in mmPerUnit.map { v * $0 } },
            valueFromPoints: fromPoints,
            // An angle is in degrees (SwiftDXF 0.6 computes one for an angular dimension), and
            // is no length to scale into millimetres.
            valueFromPointsMm: isAngle ? nil : fromPoints.flatMap { v in mmPerUnit.map { v * $0 } },
            // A text of exactly `<>` is DXF's "show the measured value": no override.
            text: d.textOverride == "<>" ? nil : d.textOverride,
            textPosition: DrawingEntities.xyz(d.textPosition),
            definitionPoints: points, layer: d.layer, color: d.color, rotationDeg: d.rotation,
            obliqueAngleDeg: d.obliqueAngle, styleName: d.styleName, handle: identity.handle,
            locator: identity.locator, via: identity.via.isEmpty ? nil : identity.via,
            blocks: identity.blocks.isEmpty ? nil : identity.blocks, rebuilt: rebuilt ? true : nil)
    }

    /// `values`, or nil when it is empty, so a record leaves out what the file does not have.
    static func nonEmpty<T>(_ values: [T]) -> [T]? { values.isEmpty ? nil : values }

    static func entityRecord(
        _ entity: DXF.Entity, index: Int, mmPerUnit: Double?, identity: DXF.Identity,
        rebuilt: Bool
    ) -> EntityRecord {
        let id = DrawingEntities.id(index)
        var record = EntityRecord(
            id: id, type: DrawingEntities.typeName(entity), layer: DrawingEntities.layer(entity),
            color: DrawingEntities.color(entity),
            bounds: DrawingEntities.bounds(of: entity).map(Box.init))
        record.handle = identity.handle
        record.locator = identity.locator
        record.via = identity.via.isEmpty ? nil : identity.via
        record.blocks = identity.blocks.isEmpty ? nil : identity.blocks
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
        case .spline(let spline):
            record.degree = spline.degree
            record.closed = spline.isClosed
            record.periodic = spline.isPeriodic
            record.rational = spline.isRational
            record.controlPoints = nonEmpty(spline.controlPoints.map(DrawingEntities.xyz))
            record.knots = nonEmpty(spline.knots)
            record.weights = nonEmpty(spline.weights)
            record.fitPoints = nonEmpty(spline.fitPoints.map(DrawingEntities.xyz))
        case .hatch(let hatch):
            record.patternName = hatch.patternName
            record.solid = hatch.isSolid
            record.boundaryPaths = hatch.paths.map(hatchPathRecord)
        case .leader(let leader):
            record.vertices = leader.vertices.map(DrawingEntities.xyz)
            record.arrowhead = leader.hasArrowhead
            record.splinePath = leader.isSpline
            record.annotationHandle = leader.annotationHandle
            record.styleName = leader.styleName
        case .dimension(let d):
            record.dimension = dimensionRecord(
                d, id: id, mmPerUnit: mmPerUnit, identity: identity, rebuilt: rebuilt)
        case .solid(let solid):
            // A filled triangle or quadrilateral, often an arrowhead: its outline, in the order
            // that walks it.
            record.vertices = solid.corners.map(DrawingEntities.xyz)
            record.closed = true
        case .wipeout(let wipeout):
            record.vertices = wipeout.boundary.map(DrawingEntities.xyz)
            record.closed = true
        case .face3D(let face):
            // Four corners in outline order; a triangle repeats its third as its fourth.
            record.vertices = face.corners.map(DrawingEntities.xyz)
            record.closed = true
        case .tolerance(let tolerance):
            // The frame string as the file writes it, where it is placed and the way it runs.
            record.at = DrawingEntities.xyz(tolerance.insertion)
            record.rotationDeg = tolerance.rotationDeg
            record.text = tolerance.text
            record.styleName = tolerance.styleName
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

    /// An optional boolean, with the same absent and `null` rule.
    static func optionalBool(_ value: Value?, name: String) throws -> Bool? {
        guard let value = present(value) else { return nil }
        guard let bool = value.boolValue else {
            throw ArgumentError(description: "`\(name)` must be true or false.")
        }
        return bool
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
    ///
    /// It carries the release line of each reader beside the hash: the ids a result names are
    /// positions in what the readers modelled, and they shift when a newer one models more.
    struct SourceRef: Encodable {
        let fileName: String
        let sha256: String
        let readerVersion: String
        let readerVersions: [String: String]
        /// The options the ids were made under: they change which entities there are.
        let options: ReadSettings
    }

    static func sourceRef(_ loaded: LoadedDrawing) -> SourceRef {
        SourceRef(
            fileName: loaded.source.fileName, sha256: loaded.source.sha256,
            readerVersion: loaded.source.readerVersion,
            readerVersions: loaded.source.readerVersions, options: loaded.settings)
    }

    /// A drawing read, or the error result that says why it was not.
    enum DrawingLoad {
        case loaded(LoadedDrawing)
        case failed(ToolText)
    }

    static func load(_ inputPath: String, settings: ReadSettings) async -> DrawingLoad {
        do {
            return .loaded(try await DrawingFile.load(path: inputPath, settings: settings))
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
        /// The scale each JWW layer group that holds a top-level element was drawn at, already
        /// multiplied out (a group used only inside blocks is not listed); absent for a DXF or a DWG.
        let layerGroupScales: [LoadedDrawing.LayerGroupScale]?
        /// How many dimensions were rebuilt from loose pieces (`rebuilt: true` in the dimension
        /// records); absent when none were.
        let rebuiltDimensions: Int?
    }

    public static func readDrawing(
        inputPath: String, settings: ReadSettings = ReadSettings()
    ) async -> ToolText {
        let loaded: LoadedDrawing
        switch await load(inputPath, settings: settings) {
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
        if !settings.expandBlocks, !drawing.references.isEmpty {
            warnings.append(
                "\(drawing.references.count) block reference(s) are not expanded (`expandBlocks` is "
                    + "false), so the geometry they place is missing from the entity list.")
        }
        // What the loader said, as data: missing and cyclic blocks, paper space, entities it could
        // not carry through a transform or read. Skipped entities are in `skipped`, and the units
        // and an empty drawing have their own messages above.
        for warning in loaded.warnings {
            switch warning.kind {
            case .skippedEntities, .unitsNotDeclared, .emptyDrawing: continue
            default: warnings.append(warning.message)
            }
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
                skipped: loaded.skipped, warnings: warnings,
                layerGroupScales: nonEmpty(loaded.layerGroupScales),
                rebuiltDimensions: loaded.rebuiltDimensions.isEmpty
                    ? nil : loaded.rebuiltDimensions.count))
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
        rectMode: String?, limit: Int?, offset: Int?, settings: ReadSettings = ReadSettings()
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
        switch await load(inputPath, settings: settings) {
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
            let identity = loaded.drawing.identity(ofEntityAt: $0)
            return entityRecord(
                loaded.drawing.entities[$0], index: $0, mmPerUnit: loaded.mmPerUnit,
                identity: identity, rebuilt: loaded.rebuiltDimensions.contains(identity))
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
        inputPath: String, layers: [String]?, kinds: [String]?, limit: Int?, offset: Int?,
        settings: ReadSettings = ReadSettings()
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
        switch await load(inputPath, settings: settings) {
        case .loaded(let value): loaded = value
        case .failed(let failure): return failure
        }
        let layerSet = layers.map(Set.init)
        let kindSet = kinds.map(Set.init)
        var all: [DimensionRecord] = []
        for (index, entity) in loaded.drawing.entities.enumerated() {
            guard case .dimension(let d) = entity else { continue }
            let identity = loaded.drawing.identity(ofEntityAt: index)
            let record = dimensionRecord(
                d, id: DrawingEntities.id(index), mmPerUnit: loaded.mmPerUnit, identity: identity,
                rebuilt: loaded.rebuiltDimensions.contains(identity))
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
