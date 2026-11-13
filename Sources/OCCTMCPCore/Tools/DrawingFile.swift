// DrawingFile: reads a 2D drawing file into OCCTSwiftIO's drawing model (SwiftDXF's `DXF.Drawing`)
// and records where it came from, what its units are and what the reader left out. The drawing
// read tools (#260) all start here. Nothing in this file touches the scene or the manifest.

import CryptoKit
import Foundation
import OCCTSwiftIO

/// Why a drawing could not be read.
enum DrawingReadError: Error, CustomStringConvertible {
    case notFound(String)
    case unsupportedFormat(extension: String, reason: String)
    case unreadable(path: String, underlying: String)

    var description: String {
        switch self {
        case .notFound(let path):
            return "Drawing file not found: \(path)"
        case .unsupportedFormat(let ext, let reason):
            return "Cannot read .\(ext) drawings: \(reason)"
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
        let bytes: Int
        let sha256: String
        let format: String
        /// The `$ACADVER` header value (for example `AC1027`), when the file has one.
        let dxfVersion: String?
        /// What turned the bytes into entities.
        let reader: String
        /// The SwiftDXF release that did it.
        ///
        /// Entity ids (`e<index>`) shift when a newer reader models more types, so it is recorded
        /// beside the SHA-256 that names the bytes.
        let readerVersion: String
    }

    /// Entities the reader does not model, as SwiftDXF reports them (`Drawing.skipped`).
    struct Skipped: Encodable, Sendable {
        var total = 0
        var byType: [String: Int] = [:]
        var byLayer: [String: [String: Int]] = [:]
    }

    let drawing: DXF.Drawing
    let source: Source
    let skipped: Skipped

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
    /// The formats this build reads, and why the others are not read.
    static let supportedFormats = ["dxf"]

    /// The SwiftDXF release this build reads with.
    ///
    /// SwiftPM has no runtime query for a dependency's version, so it is written here, and a test
    /// holds it equal to the `swiftdxf` pin in `Package.resolved`: a bump that forgets it fails.
    static let readerVersion = "0.3.0"

    /// Read `path` as a drawing, answering from a small cache when the file has not changed.
    static func load(path: String) async throws -> LoadedDrawing {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw DrawingReadError.notFound(expanded)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: expanded)
        let key = DrawingCache.Key(
            path: URL(fileURLWithPath: expanded).standardizedFileURL.path,
            size: (attributes?[.size] as? Int) ?? -1,
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        if let hit = await DrawingCache.shared.entry(for: key) { return hit }
        let loaded = try read(path: key.path)
        await DrawingCache.shared.store(loaded, for: key)
        return loaded
    }

    private static func read(path: String) throws -> LoadedDrawing {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "dxf":
            break
        case "dwg":
            throw DrawingReadError.unsupportedFormat(
                extension: ext,
                reason: "OCCTSwiftIO's DWGLoader is merged upstream (OCCTSwiftIO#53) but not in "
                    + "a tagged release at this server's pin. Convert the file to ASCII DXF.")
        case "jww":
            throw DrawingReadError.unsupportedFormat(
                extension: ext,
                reason: "OCCTSwiftIO exposes no entity model for JWW yet (OCCTSwiftIO#54). "
                    + "Convert the file to ASCII DXF.")
        default:
            throw DrawingReadError.unsupportedFormat(
                extension: ext.isEmpty ? "(none)" : ext,
                reason: "supported formats: \(supportedFormats.joined(separator: ", ")).")
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw DrawingReadError.unreadable(path: path, underlying: error.localizedDescription)
        }
        let drawing: DXF.Drawing
        do {
            // `DXFLoader.readEntities(from:)` is `DXF.read(contentsOf:)`. Parsing the bytes read
            // for the hash instead keeps the source record about exactly what was parsed.
            drawing = try DXF.read(data: data)
        } catch DXF.Error.binaryUnsupported {
            throw DrawingReadError.unreadable(
                path: path, underlying: "binary DXF is not supported; save it as ASCII DXF.")
        } catch DXF.Error.notDXF {
            throw DrawingReadError.unreadable(
                path: path, underlying: "the file is not a DXF document.")
        } catch DXF.Error.empty {
            throw DrawingReadError.unreadable(path: path, underlying: "the file is empty.")
        } catch {
            throw DrawingReadError.unreadable(path: path, underlying: error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return LoadedDrawing(
            drawing: drawing,
            source: .init(
                path: path, fileName: (path as NSString).lastPathComponent, bytes: data.count,
                sha256: digest, format: "dxf",
                dxfVersion: drawing.version.isEmpty ? nil : drawing.version,
                reader: "SwiftDXF (DXF.read), as OCCTSwiftIO DXFLoader.readEntities calls it",
                readerVersion: readerVersion),
            skipped: skipped(from: drawing))
    }

    /// What the reader left out, in the shape the tools report.
    ///
    /// SwiftDXF counts the entity records it does not model by type, and by type then layer; the
    /// tools report by type and by layer then type. It counts an `INSERT`'s `ATTRIB` records as
    /// entities of their own, so a block insert with attributes shows the attributes too.
    static func skipped(from drawing: DXF.Drawing) -> LoadedDrawing.Skipped {
        var skipped = LoadedDrawing.Skipped()
        skipped.byType = drawing.skipped
        skipped.total = drawing.skipped.values.reduce(0, +)
        for (type, layers) in drawing.skippedByLayer {
            for (layer, count) in layers {
                skipped.byLayer[layer, default: [:]][type, default: 0] += count
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
    }

    static let shared = DrawingCache()
    static let capacity = 4

    private var order: [Key] = []
    private var entries: [Key: LoadedDrawing] = [:]

    func entry(for key: Key) -> LoadedDrawing? { entries[key] }

    func store(_ drawing: LoadedDrawing, for key: Key) {
        // A changed file has a new key, so drop any older entry for the same path.
        for stale in order where stale.path == key.path && stale != key {
            entries[stale] = nil
        }
        order.removeAll { $0.path == key.path }
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
