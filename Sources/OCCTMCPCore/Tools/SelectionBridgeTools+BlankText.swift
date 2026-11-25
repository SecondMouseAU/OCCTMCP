// SelectionBridgeTools+BlankText: what the viewport host reads as no text in a `question` or a
// `label` (SecondMouseAU/OCCTMCP#293). The host (OCCTSwiftInteraction's `CADViewportService`)
// applies one rule to both, so this server applies the same one to both and the two cannot
// disagree about whether a request carries a question or a label.

import Foundation

extension SelectionBridgeTools {

    /// The scalars that draw nothing and fall outside whitespace, control and default-ignorable.
    static let blankScalars: Set<Unicode.Scalar> = [
        "\u{2800}",  // BRAILLE PATTERN BLANK
        "\u{FFF9}", "\u{FFFA}", "\u{FFFB}",  // INTERLINEAR ANNOTATION ANCHOR, SEPARATOR, TERMINATOR
        "\u{FFFC}",  // OBJECT REPLACEMENT CHARACTER
        "\u{16FE4}",  // KHITAN SMALL SCRIPT FILLER
        "\u{1D159}",  // MUSICAL SYMBOL NULL NOTEHEAD
    ]

    /// Whether `text` draws nothing, the way the viewport host decides it.
    ///
    /// True for the empty string and for a string whose every Unicode scalar is `White_Space`, a
    /// control character (general category Cc), a `Default_Ignorable_Code_Point` or one of
    /// `blankScalars`. It works on scalars, not `Character`s, so a visible scalar joined to
    /// blank ones is never hidden by grapheme clustering. The host's own copy is internal to it
    /// and not in the release this package pins, so this is a local copy of its rule.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let properties = scalar.properties
            return properties.isWhitespace || properties.generalCategory == .control
                || properties.isDefaultIgnorableCodePoint || blankScalars.contains(scalar)
        }
    }

    /// `text` as the host reads it: nil when it is nil or blank, otherwise exactly as given.
    ///
    /// A text with a visible character is never trimmed or changed.
    static func nilIfBlank(_ text: String?) -> String? {
        guard let text, !isBlank(text) else { return nil }
        return text
    }
}
