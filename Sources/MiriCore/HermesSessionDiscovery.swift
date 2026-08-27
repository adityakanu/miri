import Foundation

/// Lists Hermes sessions over its REST API.
///
/// Contract per Hermes' API-server documentation: `GET /api/sessions`,
/// paginated with `limit`/`offset`, gated by the `API_SERVER_KEY` bearer token.
/// The API server is opt-in (`API_SERVER_ENABLED=true`) and listens on
/// 127.0.0.1:8642 by default, so discovery returning nothing is the normal case
/// when the gateway is not running.
public enum HermesSessionDiscovery {
    /// Thrown so the UI can distinguish "not configured" from "server refused".
    public enum Failure: Error, Equatable, LocalizedError {
        case unauthorized
        case unreachable(String)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .unauthorized:
                "Hermes rejected the API key. Check API_SERVER_KEY in ~/.hermes/.env."
            case .unreachable(let detail):
                "Could not reach the Hermes API server: \(detail)"
            case .malformedResponse:
                "The Hermes API server returned an unexpected response."
            }
        }
    }

    public static func sessions(
        endpoint: URL,
        apiKey: String?,
        limit: Int = 30,
        session: URLSession = .shared
    ) async throws -> [AgentSessionSummary] {
        var components = URLComponents(
            url: endpoint.appending(path: "api/sessions"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw Failure.malformedResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            guard http.statusCode != 401, http.statusCode != 403 else { throw Failure.unauthorized }
            guard (200..<300).contains(http.statusCode) else {
                throw Failure.unreachable("HTTP \(http.statusCode)")
            }
        }
        return try parse(data)
    }

    /// Accepts both the documented `{"data": [...]}` envelope and a bare array,
    /// and tolerates missing optional fields rather than dropping the session.
    static func parse(_ data: Data) throws -> [AgentSessionSummary] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        switch root {
        case let object as [String: Any]:
            rows = object["data"] as? [[String: Any]] ?? []
        case let array as [[String: Any]]:
            rows = array
        default:
            throw Failure.malformedResponse
        }

        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let lastActive = (row["last_active_at"] as? String).flatMap(parseTimestamp)
                ?? (row["started_at"] as? String).flatMap(parseTimestamp)
                ?? .distantPast
            return AgentSessionSummary(
                id: id,
                agent: .hermes,
                title: title ?? "Hermes session \(id.prefix(8))",
                workingDirectory: row["working_directory"] as? String,
                lastActiveAt: lastActive
            )
        }
        .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
