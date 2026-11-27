import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads LF-delimited subprocess output as soon as the delimiter arrives, even if the child goes
/// idle waiting for the next request. Decode UTF-8 only after assembling a complete line.
nonisolated enum ECSPipeReader {
    static func readLines(
        from handle: FileHandle,
        receive: @Sendable (String) async -> Void
    ) async throws {
        var buffer = Data()
        for try await chunk in chunks(from: handle) {
            let previousEnd = buffer.endIndex
            buffer.append(chunk)
            var start = buffer.startIndex
            for end in buffer[previousEnd...].indices where buffer[end] == 0x0A {
                let lineEnd = end > start && buffer[end - 1] == 0x0D ? end - 1 : end
                await receive(String(decoding: buffer[start..<lineEnd], as: UTF8.self))
                start = end + 1
            }
            buffer.removeSubrange(..<start)
        }
        if !buffer.isEmpty && !Task.isCancelled {
            await receive(String(decoding: buffer, as: UTF8.self))
        }
    }

    private static func chunks(from handle: FileHandle) -> AsyncThrowingStream<Data, Error> {
        let fd = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.onTermination = { _ in source.cancel() }
        // Close on the source queue after any in-progress read has returned.
        source.setCancelHandler { try? handle.close() }
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                continuation.yield(Data(bytes.prefix(count)))
            } else if count == 0 {
                continuation.finish()
            } else if errno != EINTR {
                continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        }
        source.activate()
        return stream
    }
}
