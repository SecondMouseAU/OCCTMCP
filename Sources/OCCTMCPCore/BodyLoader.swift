// The one way a tool turns a manifest body into a Shape: the embedding host's own shape when it
// supplies one, otherwise the body's file read by the format the manifest names.

import Foundation
import OCCTSwift
import ScriptHarness

/// Why a body could not be turned into a shape, naming the format involved.
public enum BodyLoadError: Error, CustomStringConvertible {
    case unsupportedFormat(bodyId: String?, format: String)
    case notEditable(bodyId: String?, format: String)
    case readFailed(bodyId: String?, format: String, path: String, underlying: String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let id, let format):
            return
                "Body \(Self.label(id)) has format \"\(format)\", which this server cannot read. "
                + "Supported formats: \(BodyLoader.readableFormats.joined(separator: ", "))."
        case .notEditable(let id, let format):
            return
                "Body \(Self.label(id)) has format \"\(format)\". This tool edits brep bodies only, "
                + "because it writes its result back as BREP."
        case .readFailed(let id, let format, let path, let underlying):
            return
                "Failed to read \(format) body \(Self.label(id)) from \(path): \(underlying)"
        }
    }

    private static func label(_ id: String?) -> String { id.map { "\"\($0)\"" } ?? "(no id)" }
}

extension BodyLoadError: LocalizedError {
    /// So `error.localizedDescription`, which most tool catch sites use, carries the message
    /// instead of Foundation's generic "The operation couldn't be completed".
    public var errorDescription: String? { description }
}

public enum BodyLoader {
    /// The `format` values a body may carry and still be read.
    ///
    /// These are the formats `import_file` reads, minus `auto`, which names no format.
    public static let readableFormats = IOTools.ImportFormat.allCases.filter { $0 != .auto }
        .map(\.rawValue)

    /// The shape the embedding host holds for `body`, or nil when no provider is set or it declines.
    ///
    /// The provider is a task-local, so it reaches only the tool call it was installed around.
    public static func hostShape(for body: BodyDescriptor, outputDir: String) throws -> Shape? {
        try OCCTMCPContext.bodyShapeProvider?(body, outputDir)
    }

    /// Read a body's file by the format its manifest entry names, ignoring any host provider.
    ///
    /// `format` is matched case-insensitively and `stp`, `igs` and `brp` are accepted as aliases.
    public static func loadFromFile(body: BodyDescriptor, outputDir: String) throws -> Shape {
        let path = "\(outputDir)/\(body.file)"
        guard let format = IOTools.ImportFormat(spelling: body.format) else {
            throw BodyLoadError.unsupportedFormat(bodyId: body.id, format: body.format)
        }
        do {
            return try IOTools.loadShape(fromPath: path, as: format)
        } catch {
            throw BodyLoadError.readFailed(
                bodyId: body.id, format: body.format, path: path,
                underlying: error.localizedDescription)
        }
    }

    /// The shape for `body`: the host's when it supplies one, else the file read by format.
    public static func loadShape(body: BodyDescriptor, outputDir: String) throws -> Shape {
        if let shape = try hostShape(for: body, outputDir: outputDir) { return shape }
        return try loadFromFile(body: body, outputDir: outputDir)
    }

    /// Refuse a body a tool cannot write back to.
    ///
    /// Editing tools write BREP to the body's own file and carry its `format` onto the result, so
    /// letting one load a `step` body would overwrite the STEP file with BREP bytes.
    public static func requireEditable(_ body: BodyDescriptor) throws {
        guard IOTools.ImportFormat(spelling: body.format) == .brep else {
            throw BodyLoadError.notEditable(bodyId: body.id, format: body.format)
        }
    }

    /// The error result an editing tool returns for a body it cannot write back to, else nil.
    static func editRefusal(for body: BodyDescriptor) -> ToolText? {
        do {
            try requireEditable(body)
            return nil
        } catch {
            return ToolText("\(error)", isError: true)
        }
    }
}
