import Foundation
import XCTest
@testable import MarkdownHelpers

final class ShareLinkClientTests: XCTestCase {

    private let base = URL(string: "https://share.example")!
    private let envelope = Data("MDP1".utf8) + Data(count: 60)

    private func client(_ handler: @escaping StubProtocol.Handler) -> ShareLinkClient {
        StubProtocol.handler = handler
        return ShareLinkClient(baseURL: base,
                               session: ShareLinkClient.makeSession(protocolClasses: [StubProtocol.self]))
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testCreatePostsTheEnvelopeWithTheExpiry() async throws {
        let expected = envelope
        let client = client { request, body in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://share.example/shares?ttl=7d")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(body, expected)
            return (201, #"{"id":"abc","ownerToken":"tok","expiresAt":"2026-10-30T09:32:53.384Z"}"#)
        }
        let created = try await client.create(envelope, expiry: .week)
        XCTAssertEqual(created.id, "abc")
        XCTAssertEqual(created.ownerToken, "tok")
        XCTAssertEqual(created.expiresAt.timeIntervalSince1970, 1_793_352_773.384, accuracy: 0.001)
    }

    func testUpdateAndDeleteSendTheOwnerToken() async throws {
        let client = client { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            XCTAssertEqual(request.url?.path, "/shares/abc")
            return request.httpMethod == "PUT"
                ? (200, #"{"expiresAt":"2026-11-22T00:00:00.000Z"}"#)
                : (204, "")
        }
        _ = try await client.update(id: "abc", envelope: envelope, ownerToken: "tok", expiry: .month)
        try await client.delete(id: "abc", ownerToken: "tok")
    }

    func testFetchReturnsTheBody() async throws {
        let client = client { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, "MDP1-bytes")
        }
        let data = try await client.fetch(id: "abc")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "MDP1-bytes")
    }

    func testMapsErrorStatuses() async {
        let cases: [(Int, ShareLinkClient.Failure)] = [
            (404, .notFound), (401, .unauthorized), (413, .tooLarge), (429, .rateLimited),
            (500, .server(status: 500, code: "boom")),
        ]
        for (status, expected) in cases {
            let client = client { _, _ in (status, #"{"error":"boom"}"#) }
            do {
                _ = try await client.fetch(id: "abc")
                XCTFail("\(status) should throw")
            } catch {
                XCTAssertEqual(error as? ShareLinkClient.Failure, expected)
            }
        }
    }

    func testRejectsAMalformedCreateResponse() async {
        let client = client { _, _ in (201, #"{"id":"abc"}"#) }
        do {
            _ = try await client.create(envelope, expiry: .day)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ShareLinkClient.Failure, .invalidResponse)
        }
    }
}

/// Answers every request with the handler's status and body.
final class StubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data?) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, text) = Self.handler?(request, body) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
