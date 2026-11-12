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
    }

    /// Entities the reader does not model, counted from the raw file.
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
                reader: "SwiftDXF (DXF.read), as OCCTSwiftIO DXFLoader.readEntities calls it"),
            skipped: scanSkipped(data))
    }

    /// Entity types SwiftDXF turns into entities, plus the records that belong to a polyline.
    private static let modelledTypes: Set<String> = [
        "LINE", "CIRCLE", "ARC", "ELLIPSE", "POINT", "TEXT", "MTEXT", "LWPOLYLINE", "POLYLINE",
        "VERTEX", "SEQEND", "DIMENSION",
    ]

    /// Count the entity records SwiftDXF skips, by type and by layer.
    ///
    /// SwiftDXF 0.3.0 reports this itself (`Drawing.skipped`) and models `SPLINE`; this pin has
    /// neither, so the count is made here. When the pin moves, take SwiftDXF's and drop this.
    ///
    /// SwiftDXF reports only what it modelled, so a block insert or a hatch leaves no trace in
    /// `DXF.Drawing`. This reads the raw group-code stream of the `ENTITIES` section for the rest.
    static func scanSkipped(_ data: Data) -> LoadedDrawing.Skipped {
        // SwiftDXF's reader splits on any newline (LF, CRLF or a lone CR), so this does too.
        let text = (String(data: data, encoding: .utf8) ?? DXF.decodeCP932([UInt8](data)))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var skipped = LoadedDrawing.Skipped()
        var inEntities = false
        var pendingSection = false
        var currentType: String?
        var currentLayer = "0"
        // The last record that is not a child of another: an INSERT's ATTRIB records follow it.
        var lastParent: String?

        func finishEntity() {
            guard let type = currentType else { return }
            defer {
                if type != "ATTRIB" && type != "VERTEX" && type != "SEQEND" { lastParent = type }
            }
            if type == "ATTRIB" && lastParent == "INSERT" { return }
            guard !modelledTypes.contains(type) else { return }
            skipped.total += 1
            skipped.byType[type, default: 0] += 1
            skipped.byLayer[currentLayer, default: [:]][type, default: 0] += 1
        }

        let lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        var i = 0
        while i + 1 < lines.count {
            let codeField = String(Substring(lines[i])).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard let code = Int(codeField) else {
                i += 1
                continue
            }
            let value = String(Substring(lines[i + 1])).trimmingCharacters(
                in: .whitespacesAndNewlines)
            i += 2
            if code == 0 {
                if inEntities { finishEntity() }
                currentType = nil
                currentLayer = "0"
                switch value {
                case "SECTION":
                    pendingSection = true
                case "ENDSEC":
                    inEntities = false
                default:
                    if inEntities { currentType = value }
                }
            } else if code == 2, pendingSection {
                inEntities = value == "ENTITIES"
                pendingSection = false
            } else if code == 8, inEntities, currentType != nil {
                currentLayer = value
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
