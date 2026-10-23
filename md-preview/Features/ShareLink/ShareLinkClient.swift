//
//  ShareLinkClient.swift
//  md-preview
//
//  Talks to the share Worker (server/share-worker, docs/share-link-plan.md
//  §3). It only ever sends and receives sealed envelopes; keys never leave
//  the app. Kept free of AppKit so the SPM helper tests can exercise it
//  without a GUI host.
//

import Foundation

nonisolated struct ShareLinkClient: Sendable {

    enum Failure: Error, Equatable {
        case notFound
        case unauthorized
        case tooLarge
        case rateLimited
        case server(status: Int, code: String?)
        case invalidResponse
    }

    enum Expiry: String, CaseIterable, Codable, Sendable {
        case hour = "1h", day = "1d", week = "7d", month = "30d"
    }

    struct Created: Equatable, Sendable {
        let id: String
        let ownerToken: String
        let expiresAt: Date
    }

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = Self.makeSession()) {
        self.baseURL = baseURL
        self.session = session
    }

    /// No cookies, no cache, like `UsageAnalyticsReporter`.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    func create(_ envelope: Data, expiry: Expiry) async throws -> Created {
        var request = URLRequest(url: url(id: nil, expiry: expiry))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: envelope, expecting: 201)
        guard let body = try? JSONDecoder().decode([String: String].self, from: data),
              let id = body["id"], let ownerToken = body["ownerToken"],
              let expiresAt = body["expiresAt"].flatMap(Self.date)
        else { throw Failure.invalidResponse }
        return Created(id: id, ownerToken: ownerToken, expiresAt: expiresAt)
    }

    /// Replaces the share's envelope and returns the new expiry.
    func update(id: String, envelope: Data, ownerToken: String, expiry: Expiry) async throws -> Date {
        var request = URLRequest(url: url(id: id, expiry: expiry))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request, body: envelope, expecting: 200)
        guard let body = try? JSONDecoder().decode([String: String].self, from: data),
              let expiresAt = body["expiresAt"].flatMap(Self.date)
        else { throw Failure.invalidResponse }
        return expiresAt
    }

    func delete(id: String, ownerToken: String) async throws {
        var request = URLRequest(url: url(id: id, expiry: nil))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        _ = try await send(request, body: nil, expecting: 204)
    }

    func fetch(id: String) async throws -> Data {
        try await send(URLRequest(url: url(id: id, expiry: nil)), body: nil, expecting: 200)
    }

    // MARK: - Private

    private func url(id: String?, expiry: Expiry?) -> URL {
        var url = baseURL.appendingPathComponent("shares")
        if let id { url.appendPathComponent(id) }
        if let expiry { url.append(queryItems: [URLQueryItem(name: "ttl", value: expiry.rawValue)]) }
        return url
    }

    private func send(_ request: URLRequest, body: Data?, expecting status: Int) async throws -> Data {
        let (data, response) = if let body {
            try await session.upload(for: request, from: body)
        } else {
            try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard http.statusCode != status else { return data }

        let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
        switch http.statusCode {
        case 404: throw Failure.notFound
        case 401: throw Failure.unauthorized
        case 413: throw Failure.tooLarge
        case 429: throw Failure.rateLimited
        default: throw Failure.server(status: http.statusCode, code: code)
        }
    }

    private static func date(_ string: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }
}
