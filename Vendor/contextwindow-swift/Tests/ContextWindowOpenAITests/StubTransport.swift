import Foundation
@testable import ContextWindowOpenAI

/// A network-free ``OpenAITransport`` test double.
///
/// Returns scripted `(Data, HTTPURLResponse)` pairs in order and captures every
/// ``OpenAIHTTPRequest`` it was handed so tests can assert request shape. The
/// default suite uses only this — **zero** network.
final class StubTransport: OpenAITransport, @unchecked Sendable {
    struct Scripted: Sendable {
        var status: Int
        var json: String
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var responses: [Scripted] = []
        var captured: [OpenAIHTTPRequest] = []
    }

    private let box = Box()

    init(responses: [Scripted]) {
        box.responses = responses
    }

    /// Convenience: a single 200 JSON response.
    convenience init(json: String) {
        self.init(responses: [Scripted(status: 200, json: json)])
    }

    func send(_ request: OpenAIHTTPRequest) async throws -> (Data, HTTPURLResponse) {
        let scripted: Scripted = box.lock.withLock {
            box.captured.append(request)
            guard !box.responses.isEmpty else {
                return Scripted(status: 500, json: #"{"error":"stub exhausted"}"#)
            }
            return box.responses.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url,
            statusCode: scripted.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(scripted.json.utf8), response)
    }

    /// All requests sent, in order.
    var capturedRequests: [OpenAIHTTPRequest] {
        box.lock.withLock { box.captured }
    }

    /// Number of requests sent.
    var sendCount: Int {
        box.lock.withLock { box.captured.count }
    }

    /// Decode a captured request body to a dictionary for shape assertions.
    func bodyJSON(_ index: Int) -> [String: Any] {
        let req = box.lock.withLock { box.captured[index] }
        let obj = try! JSONSerialization.jsonObject(with: req.body)
        return obj as! [String: Any]
    }
}
