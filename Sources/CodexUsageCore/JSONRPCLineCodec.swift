import Foundation

public struct JSONRPCLineCodec {
    private static let maximumBufferedBytes = 4 * 1024 * 1024
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []

        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else { continue }
            messages.append(message)
        }

        if buffer.count > Self.maximumBufferedBytes {
            buffer.removeAll(keepingCapacity: false)
        }
        return messages
    }

    public func encode(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(10)
        return data
    }
}
