// SelectionBridgeTools+DrawingEntity: a pick on a 2D drawing entity in `get_selection`
// (SecondMouseAU/OCCTMCP#277). The pick names a drawing case the host holds and no scene
// geometry, so it is passed through as itself and never resolved against this server's scene.

import Foundation

extension SelectionBridgeTools {

    /// The `kind` of a pick on a 2D drawing entity.
    static let drawingEntityKind = "drawing-entity"

    /// The per-entry error for a kind this server does not know.
    static func unknownKindMessage(_ kind: String) -> String {
        "unknown kind '\(kind)'. Expected one of: \(validKinds.joined(separator: ", ")), "
            + "\(drawingEntityKind)."
    }

    /// Pass a `drawing-entity` pick through as itself, without touching the scene.
    ///
    /// The row carries `bodyId` (the drawing case), `kind`, `entity` and `entityType`, and no
    /// `selectionId`, `anchor`, `index` or `uid`. A pick with no usable `entity` names nothing,
    /// so its row carries an `error` and no `entity`.
    static func resolveDrawingEntity(_ entry: SelectionJSONEntry) -> ResolvedSelection {
        let named =
            entry.entity.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? false
        return ResolvedSelection(
            selectionId: nil, bodyId: entry.bodyId, kind: entry.kind, index: nil, uid: nil,
            anchor: nil,
            error: named
                ? nil
                : "\(drawingEntityKind) pick on \(entry.bodyId) has no usable entity: the host "
                    + "wrote none, or one that is null, empty, blank or not a string.",
            entity: named ? entry.entity : nil, entityType: entry.entityType)
    }
}
