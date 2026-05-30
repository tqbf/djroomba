import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single HTTP request the OpenAI adapters issue.
///
/// Adapters build these; the injected ``OpenAITransport`` performs them. This
/// indirection is the cost-discipline seam: tests inject a fake transport that
/// returns canned JSON, so `swift test` never touches the network.
public struct OpenAIHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// The HTTP boundary the OpenAI adapters depend on.
///
/// Production code uses ``URLSessionOpenAITransport``; tests inject a stub that
/// returns canned `(Data, HTTPURLResponse)` pairs. Keeping this a small
/// `Sendable` protocol means the adapter logic is fully exercisable offline.
public protocol OpenAITransport: Sendable {
    func send(_ request: OpenAIHTTPRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default `URLSession`-backed transport.
///
/// This is the only type in the OpenAI module that can perform real network
/// I/O. It is never used by the default test suite (those inject a stub); the
/// gated live test constructs one explicitly.
public struct URLSessionOpenAITransport: OpenAITransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: OpenAIHTTPRequest) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.nonHTTPResponse
        }
        return (data, http)
    }
}

/// Errors surfaced by the OpenAI adapters.
public enum OpenAIError: Error, Sendable, Equatable {
    /// The `OPENAI_API_KEY` environment variable was not set and no key was
    /// supplied explicitly.
    case missingAPIKey
    /// The transport returned a non-HTTP response.
    case nonHTTPResponse
    /// The API returned a non-2xx status. Carries the status code and the
    /// (possibly truncated) response body for diagnostics — never the key.
    case httpStatus(code: Int, body: String)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)
    /// The model returned no usable content (no message, no tool calls).
    case emptyResponse
    /// A tool-call loop exceeded the configured maximum number of round trips.
    case toolLoopLimitExceeded(Int)
}

extension OpenAIError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is not set and no API key was supplied"
        case .nonHTTPResponse:
            return "the transport returned a non-HTTP response"
        case .httpStatus(let code, let body):
            return "OpenAI returned HTTP \(code): \(body)"
        case .decoding(let detail):
            return "failed to decode the OpenAI response: \(detail)"
        case .emptyResponse:
            return "the OpenAI response contained no usable content"
        case .toolLoopLimitExceeded(let limit):
            return "the tool-call loop exceeded \(limit) round trips"
        }
    }
}
