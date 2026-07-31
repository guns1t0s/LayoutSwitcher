import Foundation

/// Pure, deterministic computation of WHAT to delete and insert when applying a
/// correction. This is the historically bug-prone arithmetic ("half a word",
/// "deleted the whole word") — extracted from the AppKit-bound coordinator so it
/// can be unit-tested in isolation.
public struct ReplacePlan: Equatable {
    public let deleteCount: Int        // backspaces to send
    public let insertText: String      // text to insert after
    public let convertedExtras: String // the absorbed next-word characters, converted
}

public enum CorrectionPlanner {

    /// Map a word-boundary character to what the user MEANT in the target layout.
    /// Deliberately minimal: most boundaries (space, newline, sentence "." / ",")
    /// are layout-independent and must stay verbatim. The one clear case is "^" —
    /// it only appears when ⇧6 was pressed on the EN layout, and a user with the
    /// "RU ⇧6 = comma" preference meant "," there; a conversion to RU should
    /// carry that intent instead of leaving a stray caret.
    public static func mapBoundary(_ boundary: Character?, to layout: Layout,
                                   ruShift6Comma: Bool) -> Character? {
        if layout == .ru, ruShift6Comma, boundary == "^" { return "," }
        return boundary
    }

    /// Auto-conversion at a word boundary, absorbing any characters of the NEXT
    /// word already typed in the same wrong layout. The boundary char (space /
    /// newline / tab) is preserved; the extras are re-typed converted.
    ///
    /// On-screen before: `<original><boundary?><extras>`  (caret at the end)
    /// After:            `<converted><boundary?><convertedExtras>`
    public static func autoConvert(original: String, converted: String,
                                   boundary: Character?, extras: String,
                                   extrasTo layout: Layout) -> ReplacePlan {
        let convertedExtras = extras.isEmpty ? "" : KeyMap.convert(extras, to: layout)
        let b = boundary.map(String.init) ?? ""
        return ReplacePlan(
            deleteCount: original.count + b.count + extras.count,
            insertText: converted + b + convertedExtras,
            convertedExtras: convertedExtras
        )
    }

    /// Synchronous boundary conversion where the boundary keystroke is SWALLOWED
    /// (consumed in the tap callback before delivery) and re-inserted by us. No
    /// async gap exists, so a following keystroke can't race the replacement out.
    ///
    /// On-screen before: `<original>` — the boundary char has NOT been delivered
    /// yet (we are about to drop it). After: `<converted><boundary>`. Hence
    /// deleteCount covers the word only; the boundary lives in insertText.
    public static func autoConvertSwallow(original: String, converted: String,
                                          boundary: Character?) -> ReplacePlan {
        let b = boundary.map(String.init) ?? ""
        return ReplacePlan(deleteCount: original.count,
                           insertText: converted + b, convertedExtras: "")
    }

    /// Plain replacement of a finished word (+ optional trailing boundary) with
    /// fixed text — snippets, manual fix, undo. No extras absorbed.
    public static func replace(original: String, with text: String,
                               boundary: Character?) -> ReplacePlan {
        let b = boundary.map(String.init) ?? ""
        return ReplacePlan(deleteCount: original.count + b.count,
                           insertText: text + b, convertedExtras: "")
    }
}
