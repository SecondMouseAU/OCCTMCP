// DrawingFile: reads a 2D drawing file (DXF, DWG or JWW) through OCCTSwiftIO's `DrawingLoader` into
// SwiftDXF's `DXF.Drawing`, and records where it came from, what its units are and what the reader
// left out. The drawing read tools (#260, #271) all start here. Nothing in this file touches the
// scene or the manifest.

import Foundation
import OCCTSwiftIO

/// Why a drawing could not be read.
enum DrawingReadError: Error, CustomStringConvertible {
    case notFound(String)
    case unreadable(path: String, underlying: String)

    var description: String {
        switch self {
        case .notFound(let path):
            return "Drawing file not found: \(path)"
        case .unreadable(let path, let underlying):
            return "Failed to read drawing \(path): \(underlying)"
        }
    }
}

/// A drawing read from disk, with its source record and what the reader left out.
struct LoadedDrawing: Sendable {
    struct Source: Encodable, Sendable {
        let path: String
        let fileName: String
        /// The size on disk when the file was opened; `sha256` is the authority on what was read.
        let bytes: Int
        let sha256: String
        /// `dxf`, `dwg` or `jww`, told from the file's bytes.
        let format: String
        /// The `$ACADVER` header value (for example `AC1027`) of a DXF, when the file has one.
        let dxfVersion: String?
        /// The format's own version: `$ACADVER` for a DXF, the version code for a DWG
        /// (`AC1032`), the file version for a JWW.
        let formatVersion: String
        /// What turned the bytes into entities.
        let reader: String
        /// The SwiftDXF release line that did it, such as `0.5`.
        ///
        /// Entity ids (`e<index>`) shift when a newer reader models more types, so it is recorded
        /// beside the SHA-256 that names the bytes.
        let readerVersion: String
        /// The options the file was read with: the ids depend on them.
        let options: DrawingReadTools.ReadSettings
    }

    /// Entities the reader does not model, from the loader's `skippedEntities` warnings.
    ///
    /// A DWG's skipped entities, and a JWW's solid fills, are counted without their layer, so they
    /// are in `byType` and `total` but not in `byLayer`.
    struct Skipped: Encodable, Sendable {
        var total = 0
        var byType: [String: Int] = [:]
        var byLayer: [String: [String: Int]] = [:]
    }

    let drawing: DXF.Drawing
    let source: Source
    let skipped: Skipped
    /// Everything the loader said about the read, as data: skipped and unreadable entities, paper
    /// space, missing blocks, units, an empty drawing.
    let warnings: [DrawingWarning]
    /// The options the drawing was read with: the entity ids depend on them.
    let settings: DrawingReadTools.ReadSettings
    /// The scale each JWW layer group that holds a top-level element was drawn at.
    ///
    /// A group used only inside blocks is not listed.
    ///
    /// The reader has already multiplied each one out, so a JWW's geometry is at full size. Empty
    /// for a DXF or a DWG.
    let layerGroupScales: [LayerGroupScale]
    /// The `.dimension` entities the reader rebuilt from loose pieces, not read as stored.
    ///
    /// Only a JWW has any. A dimension whose identity is not here was stored in the file.
    let rebuiltDimensions: Set<DXF.Identity>

    /// A JWW layer group and the scale its lengths were multiplied by.
    struct LayerGroupScale: Encodable, Sendable {
        /// The group number, 0 to 15.
        let group: Int
        /// The start of the names of the group's layers, such as `0-`.
        let layerNamePrefix: String
        /// The scale denominator applied: 80 for a group drawn at 1:80, 1 for a group that states no
        /// usable scale (which also has a warning).
        let scale: Double
    }

    /// Millimetres in one drawing unit, nil when the file declares no units.
    var mmPerUnit: Double? { DrawingUnits.mmPerUnit(insUnits: drawing.insUnits) }
}

/// The drawing units a DXF file declares in `$INSUNITS`.
enum DrawingUnits {
    /// `$INSUNITS` code to unit name and millimetres per unit, codes 0 to 24 as ezdxf lists them.
    private static let table: [Int: (name: String, mm: Double?)] = [
        0: ("unitless", nil),
        1: ("inches", 25.4),
        2: ("feet", 304.8),
        3: ("miles", 1_609_344),
        4: ("millimetres", 1),
        5: ("centimetres", 10),
        6: ("metres", 1000),
        7: ("kilometres", 1_000_000),
        8: ("microinches", 25.4e-6),
        9: ("mils", 0.0254),
        10: ("yards", 914.4),
        11: ("angstroms", 1e-7),
        12: ("nanometres", 1e-6),
        13: ("microns", 1e-3),
        14: ("decimetres", 100),
        15: ("decametres", 10_000),
        16: ("hectometres", 100_000),
        17: ("gigametres", 1e12),
        18: ("astronomical units", 149_597_870_700.0 * 1000),
        19: ("light years", 9_460_730_472_580_800.0 * 1000),
        20: ("parsecs", 149_597_870_700.0 * 648_000 / Double.pi * 1000),
        21: ("US survey feet", 1200.0 / 3937.0 * 1000),
        22: ("US survey inches", 1200.0 / 3937.0 * 1000 / 12),
        23: ("US survey yards", 1200.0 / 3937.0 * 1000 * 3),
        24: ("US survey miles", 1200.0 / 3937.0 * 1000 * 5280),
    ]

    static func name(insUnits: Int?) -> String {
        guard let code = insUnits else { return "undeclared" }
        return table[code]?.name ?? "unknown code \(code)"
    }

    /// Millimetres per drawing unit, nil for an undeclared, unitless or unknown code.
    static func mmPerUnit(insUnits: Int?) -> Double? {
        guard let code = insUnits else { return nil }
        return table[code]?.mm
    }
}

enum DrawingFile {
    /// The SwiftDXF release line this build reads with: major and minor, the part that decides which
    /// entity types are modelled and so which ids an entity gets.
    ///
    /// SwiftPM has no runtime query for a dependency's version, so it is written here, and a test
    /// holds it equal to the `swiftdxf` pin in `Package.resolved`: a bump that forgets it fails.
    /// The SwiftDXF release line (major and minor) this build was written for; a test holds it to
    /// the `swiftdxf` pin in `Package.resolved`.
    static let readerVersion = "0.5"

    /// Read `path` as a drawing, answering from a small cache when the file has not changed.
    ///
    /// The cache is keyed on the options too: the ids depend on whether blocks were expanded.
    static func load(
        path: String, settings: DrawingReadTools.ReadSettings = .init()
    ) async throws -> LoadedDrawing {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw DrawingReadError.notFound(expanded)
        }
        // `attributesOfItem` does not follow a symlink: ask about the file it points to, so the size
        // is the file's and the cache notices an edit to it.
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path)
        let key = DrawingCache.Key(
            path: URL(fileURLWithPath: expanded).standardizedFileURL.path,
            size: (attributes?[.size] as? Int) ?? -1,
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            settings: settings)
        if let hit = await DrawingCache.shared.entry(for: key) { return hit }
        let loaded = try read(path: key.path, bytes: key.size, settings: settings)
        await DrawingCache.shared.store(loaded, for: key)
        return loaded
    }

    private static func read(
        path: String, bytes: Int, settings: DrawingReadTools.ReadSettings
    ) throws -> LoadedDrawing {
        let result: DrawingResult
        do {
            // The loader tells the format from the bytes, reads the file once and hashes what it
            // parsed, so the source record is about exactly what the entities came from.
            result = try DrawingLoader.read(
                from: URL(fileURLWithPath: path),
                options: .init(
                    expandBlocks: settings.expandBlocks, skipPaperSpace: settings.skipPaperSpace))
        } catch DXF.Error.binaryUnsupported {
            throw DrawingReadError.unreadable(
                path: path, underlying: "binary DXF is not supported; save it as ASCII DXF.")
        } catch DXF.Error.notDXF {
            throw DrawingReadError.unreadable(
                path: path, underlying: "the file is not a DXF document.")
        } catch DXF.Error.empty {
            throw DrawingReadError.unreadable(path: path, underlying: "the file is empty.")
        } catch {
            throw DrawingReadError.unreadable(path: path, underlying: describe(error))
        }
        let drawing = result.drawing
        let isDXF = result.source.format == .dxf
        return LoadedDrawing(
            drawing: drawing,
            source: .init(
                path: path, fileName: result.source.fileName, bytes: bytes,
                sha256: result.source.sha256, format: result.source.format.rawValue,
                dxfVersion: isDXF && !drawing.version.isEmpty ? drawing.version : nil,
                formatVersion: result.source.version,
                reader: "OCCTSwiftIO DrawingLoader (SwiftDXF for DXF, SwiftDWG for DWG, "
                    + "SwiftJWW for JWW)",
                readerVersion: readerVersion, options: settings),
            skipped: skipped(from: result.warnings), warnings: result.warnings,
            settings: settings,
            layerGroupScales: result.layerGroupScales.map {
                .init(group: $0.group, layerNamePrefix: $0.layerNamePrefix, scale: $0.scale)
            },
            rebuiltDimensions: Set(result.rebuiltDimensions.map(\.identity)))
    }

    /// Why a read failed, in words.
    ///
    /// A file-system error (no permission, gone) is a Cocoa error whose `description` is a raw
    /// dump; its localised text says what happened. A DWG's `DWG.Error` and the loader's own errors
    /// are not localised and describe themselves.
    private static func describe(_ error: Error) -> String {
        (error as NSError).domain == NSCocoaErrorDomain ? error.localizedDescription : "\(error)"
    }

    /// What the reader left out, in the shape the tools report: the loader's `skippedEntities`
    /// warnings, by type and, where the format says, by layer.
    ///
    /// What the reader skipped, by type and layer, from the loader's warnings.
    ///
    /// An `INSERT` is among them only when it was not expanded.
    static func skipped(from warnings: [DrawingWarning]) -> LoadedDrawing.Skipped {
        var skipped = LoadedDrawing.Skipped()
        for warning in warnings where warning.kind == .skippedEntities {
            guard let type = warning.type else { continue }
            skipped.total += warning.count
            skipped.byType[type, default: 0] += warning.count
            if let layer = warning.layer {
                skipped.byLayer[layer, default: [:]][type, default: 0] += warning.count
            }
        }
        return skipped
    }
}

/// The last few drawings read, so a run of tool calls on one file parses it once.
actor DrawingCache {
    struct Key: Hashable, Sendable {
        let path: String
        let size: Int
        let modified: TimeInterval
        let settings: DrawingReadTools.ReadSettings
    }

    static let shared = DrawingCache()
    static let capacity = 4

    private var order: [Key] = []
    private var entries: [Key: LoadedDrawing] = [:]

    func entry(for key: Key) -> LoadedDrawing? { entries[key] }

    func store(_ drawing: LoadedDrawing, for key: Key) {
        // A changed file has a new size or time, so drop every older entry for the same path,
        // whatever settings it was read under. The same bytes read under other settings stay: the
        // ids differ between them, and a client alternating the two should not re-parse each time.
        let stale = order.filter {
            $0.path == key.path && ($0.size != key.size || $0.modified != key.modified)
        }
        for old in stale { entries[old] = nil }
        order.removeAll { $0 == key || stale.contains($0) }
        order.append(key)
        entries[key] = drawing
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    func clear() {
        order.removeAll()
        entries.removeAll()
    }
}
