import Foundation

public struct JSONRPCLineCodec {
    private static let maximumBufferedBytes = 4 * 1024 * 1024
    private var buffer = Data()
    private var discardingOversizedFrame = false

    public init() {}

    public mutating func append(_ data: Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !discardingOversizedFrame {
                let count = data.distance(from: start, to: end)
                if count > Self.maximumBufferedBytes - buffer.count {
                    buffer.removeAll(keepingCapacity: false)
                    discardingOversizedFrame = true
                } else {
                    buffer.append(contentsOf: data[start..<end])
                }
            }
            guard let newline else { break }
            if !discardingOversizedFrame, !buffer.isEmpty,
               let object = try? JSONSerialization.jsonObject(with: buffer),
               let message = object as? [String: Any] {
                messages.append(message)
            }
            buffer.removeAll(keepingCapacity: false)
            discardingOversizedFrame = false
            start = data.index(after: newline)
        }
        return messages
    }

    public func encode(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(10)
        return data
    }
}
