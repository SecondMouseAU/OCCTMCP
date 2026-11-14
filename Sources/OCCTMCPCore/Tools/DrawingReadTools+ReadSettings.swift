// DrawingReadTools+ReadSettings: the two options that change what a drawing read gives (#271).

import Foundation
import MCP

extension DrawingReadTools {

    /// How a drawing is read, which the entity ids depend on.
    ///
    /// Every tool takes both, and echoes them in its result.
    public struct ReadSettings: Hashable, Sendable, Encodable {
        /// Flatten block references into the entities.
        ///
        /// A block insert then places the geometry it stands for. On by default, as in
        /// OCCTSwiftIO's `DrawingLoader`.
        public var expandBlocks: Bool
        /// Leave paper-space entities out, as a model-space read does.
        public var skipPaperSpace: Bool

        public init(expandBlocks: Bool = true, skipPaperSpace: Bool = false) {
            self.expandBlocks = expandBlocks
            self.skipPaperSpace = skipPaperSpace
        }
    }

    /// The argument names the read settings take, which every drawing tool accepts.
    static let readSettingNames = ["expandBlocks", "skipPaperSpace"]

    /// The read settings in `arguments`, defaulted where absent or JSON `null`.
    static func readSettings(_ arguments: [String: Value]) throws -> ReadSettings {
        var settings = ReadSettings()
        if let expand = try optionalBool(arguments["expandBlocks"], name: "expandBlocks") {
            settings.expandBlocks = expand
        }
        if let skip = try optionalBool(arguments["skipPaperSpace"], name: "skipPaperSpace") {
            settings.skipPaperSpace = skip
        }
        return settings
    }

    /// `schema` with the read settings added to its properties, so every drawing tool offers them.
    static func withReadSettings(_ schema: Value) -> Value {
        guard var object = schema.objectValue, var properties = object["properties"]?.objectValue
        else { return schema }
        properties["expandBlocks"] = .object([
            "type": .string("boolean"),
            "description": .string(
                "Flatten block references (INSERT) into the entities, so a block insert places the geometry it stands for and each expanded entity's `via` names the reference. Default true. Entity ids (e<index>) depend on it, and every result echoes it under `source.options`."
            ),
        ])
        properties["skipPaperSpace"] = .object([
            "type": .string("boolean"),
            "description": .string(
                "Leave paper-space entities out, as a model-space read does. Default false. Entity ids depend on it."
            ),
        ])
        object["properties"] = .object(properties)
        return .object(object)
    }
}
