// GitHub traffic has two fixed origins, no ambient cookies and no redirects.
// A delegate caps bytes while receiving them rather than after buffering a
// response. Each call owns one session; cancellation closes it and at most the
// authorization and visible-item owners may call concurrently. Fixtures replace
// the narrow exchange closure, without borrowing the user's GitHub credentials.

import Foundation

struct GitHubReply {
    let status: Int
    let headers: [String: String]
    let data: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    func failure(at now: Date) -> GitHubFailure? {
        switch status {
        case 200..<300, 304: return nil
        case 401: return .unauthorized
        case 404: return .notFound
        case 429: return .rateLimited
        case 403:
            return header("retry-after") != nil || header("x-ratelimit-remaining") == "0"
                || String(data: data, encoding: .utf8)?.localizedCaseInsensitiveContains("rate limit") == true
                ? .rateLimited : .forbidden
        default: return .unavailable
        }
    }

    func retryDate(at now: Date) -> Date? {
        if let value = header("retry-after") {
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                return now.addingTimeInterval(seconds)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(now, date) }
        }
        if header("x-ratelimit-remaining") == "0", let value = header("x-ratelimit-reset"),
           let seconds = Double(value), seconds.isFinite {
            return max(now, Date(timeIntervalSince1970: seconds).addingTimeInterval(1))
        }
        return failure(at: now) == .rateLimited ? now.addingTimeInterval(60) : nil
    }
}

struct GitHubHTTP {
    typealias Exchange = (URLRequest) async throws -> GitHubReply
    let exchange: Exchange
    static let limit = 1_024 * 1_024

    init(exchange: @escaping Exchange = { try await GitHubFlight().send($0) }) {
        self.exchange = { request in
            guard Self.allowed(request) else { throw GitHubFailure.invalidResponse }
            return try await exchange(request)
        }
    }

    /// URLProtocol fixtures exercise the real receiving delegate without Internet traffic.
    init(configuration: URLSessionConfiguration) {
        self.init(exchange: { try await GitHubFlight(configuration: configuration).send($0) })
    }

    private static func allowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.query == nil, parts.fragment == nil,
              (request.httpBody?.count ?? 0) <= 16_384 else { return false }
        if parts.host == "api.github.com" { return request.httpMethod == "GET" }
        return parts.host == "github.com" && request.httpMethod == "POST"
            && ["/login/device/code", "/login/oauth/access_token"].contains(parts.path)
            && request.value(forHTTPHeaderField: "Authorization") == nil
    }

    /// Paths come from the caller's finite API operations, never a visited URL.
    static func request(path: String, token: String? = nil, form: [String: String]? = nil,
                        etag: String? = nil) throws -> URLRequest {
        let oauth = path == "/login/device/code" || path == "/login/oauth/access_token"
        guard path.first == "/", !path.contains("?"), !path.contains("#"), !path.split(separator: "/").contains(".."),
              (!oauth || token == nil),
              let url = URL(string: (oauth ? "https://github.com" : "https://api.github.com") + path),
              url.host == (oauth ? "github.com" : "api.github.com") else { throw GitHubFailure.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Escale", forHTTPHeaderField: "User-Agent")
        request.setValue(oauth ? "application/json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        if !oauth { request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version") }
        if let token {
            guard GitHubToken.validSecret(token) else { throw GitHubFailure.invalidResponse }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let etag, etag.utf8.count <= 512, !etag.contains("\r"), !etag.contains("\n") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let form {
            guard oauth else { throw GitHubFailure.invalidResponse }
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(form.keys.sorted().map {
                ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
                    + (form[$0]?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&").utf8)
        }
        return request
    }
}

private final class GitHubFlight: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GitHubReply, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var stopped = false
    private var response: HTTPURLResponse?
    private var body = Data()
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func send(_ request: URLRequest) async throws -> GitHubReply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !stopped else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = configuration
                config.urlCache = nil
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.httpShouldSetCookies = false
                config.timeoutIntervalForResource = 30
                config.httpMaximumConnectionsPerHost = 1
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
                lock.unlock()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<GitHubReply, Error>) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let continuation = continuation, session = session
        self.continuation = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(GitHubFailure.invalidResponse))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= GitHubHTTP.limit else {
            completionHandler(.cancel)
            finish(.failure(GitHubFailure.invalidResponse))
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= GitHubHTTP.limit - body.count else {
            finish(.failure(GitHubFailure.invalidResponse))
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error is CancellationError || (error as? URLError)?.code == .cancelled
                ? GitHubFailure.cancelled : GitHubFailure.offline))
            return
        }
        guard let response else { finish(.failure(GitHubFailure.invalidResponse)); return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        finish(.success(GitHubReply(status: response.statusCode, headers: headers, data: body)))
    }
}
