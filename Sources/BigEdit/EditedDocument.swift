import Foundation

/// The document as the user works with it: the memory-mapped original file
/// with any unsaved edits applied on demand.
///
/// This is the single read funnel between the UI and the underlying bytes.
/// Every byte the viewport decodes, measures, or copies comes through here, so
/// the storage behind it can change without touching the views. Today the
/// logical byte space equals the original file's and the only transformation
/// is the deferred replacement rule; Stage 2 slots a piece table in behind
/// this façade so positional edits can shift the logical space.
final class EditedDocument {

    /// The memory-mapped original file. Exposed for the components that speak
    /// original byte offsets — the line index, search, and save.
    let file: MappedFile

    /// The deferred-edit model whose rule (if any) transforms displayed text.
    let editModel: EditModel

    init(file: MappedFile, editModel: EditModel) {
        self.file = file
        self.editModel = editModel
    }

    /// The document length in bytes.
    var length: Int {
        file.size
    }

    /// Whether displayed text currently differs from the underlying bytes
    /// (a replacement rule is active).
    var hasDisplayTransform: Bool {
        editModel.rule != nil
    }

    /// The byte at `offset`, or `nil` outside the document.
    func byte(at offset: Int) -> UInt8? {
        var result: UInt8?
        if offset >= 0 && offset < file.size {
            result = file.buffer[offset]
        }
        return result
    }

    /// Copies the underlying bytes in `range`, without display transforms.
    /// The range is clamped to the document bounds.
    func bytes(in range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        let clamped = range.clamped(to: 0..<file.size)
        if !clamped.isEmpty {
            result = Array(UnsafeRawBufferPointer(rebasing: file.buffer[clamped]))
        }
        return result
    }

    /// The bytes in `range` as they should be displayed — with the active
    /// replacement rule spliced in, if any.
    func displayBytes(in range: Range<Int>) -> [UInt8] {
        let clamped = range.clamped(to: 0..<file.size)
        return editModel.transformedBytes(forOriginalRange: clamped, in: file.buffer)
    }

    // MARK: - UTF-8 character stepping

    /// The byte offset of the next UTF-8 character boundary after `offset`.
    func nextCharacterOffset(after offset: Int) -> Int {
        let size = file.size
        var result = size
        if offset < size {
            let buffer = file.buffer
            var candidate = offset + 1
            while candidate < size && (buffer[candidate] & 0xC0) == 0x80 {
                candidate += 1
            }
            result = candidate
        }
        return result
    }

    /// The byte offset of the previous UTF-8 character boundary before `offset`.
    func previousCharacterOffset(before offset: Int) -> Int {
        var result = 0
        if offset > 0 {
            let buffer = file.buffer
            var candidate = offset - 1
            while candidate > 0 && (buffer[candidate] & 0xC0) == 0x80 {
                candidate -= 1
            }
            result = candidate
        }
        return result
    }
}
