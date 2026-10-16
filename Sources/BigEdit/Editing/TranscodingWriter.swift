import Foundation

/// Streams a single-byte document to a file as UTF-8 — the conversion that
/// lets it hold any character. The logical document is read in windows,
/// each converted byte by byte and written out, so nothing is held beyond a
/// window however large the file.
extension FileWriter {

    /// Writes `document`, whose bytes are in `encoding`, to `destination` as
    /// UTF-8. Runs on a background queue; callbacks fire on the main queue.
    static func save(
        document: EditedDocument,
        convertingFrom encoding: TextEncoding,
        to destination: URL,
        cancelToken: CancelToken,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, WriteError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = saveSynchronously(document: document, convertingFrom: encoding,
                                           to: destination, cancelToken: cancelToken) { fraction in
                DispatchQueue.main.async { onProgress(fraction) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The same on the calling thread, for tests.
    static func saveSynchronously(
        document: EditedDocument,
        convertingFrom encoding: TextEncoding,
        to destination: URL,
        cancelToken: CancelToken = CancelToken(),
        windowSize: Int = lineFilterWindow,
        onProgress: (Double) -> Void = { _ in }
    ) -> Result<Void, WriteError> {
        performWrite(destination: destination) { descriptor in
            streamTranscoding(fd: descriptor, document: document, encoding: encoding,
                              cancelToken: cancelToken, windowSize: windowSize,
                              onProgress: onProgress)
        }
    }

    private static func streamTranscoding(
        fd: Int32,
        document: EditedDocument,
        encoding: TextEncoding,
        cancelToken: CancelToken,
        windowSize: Int,
        onProgress: (Double) -> Void
    ) -> Result<Void, WriteError> {
        let total = document.length
        var cursor = 0
        var result: Result<Void, WriteError> = .success(())
        while cursor < total, case .success = result {
            if cancelToken.isCancelled {
                result = .failure(.cancelled)
            } else {
                let window = cursor..<min(total, cursor + windowSize)
                let converted = encoding.transcodedToUTF8(document.bytes(in: window))
                result = writeAll(converted, fd: fd)
                cursor = window.upperBound
                onProgress(Double(cursor) / Double(total))
            }
        }
        return result
    }

    private static func writeAll(_ bytes: [UInt8], fd: Int32) -> Result<Void, WriteError> {
        bytes.withUnsafeBytes { raw in
            var result: Result<Void, WriteError> = .success(())
            if let pointer = raw.baseAddress, raw.count > 0 {
                result = writeBytes(fd: fd, pointer: pointer, count: raw.count)
            }
            return result
        }
    }
}
