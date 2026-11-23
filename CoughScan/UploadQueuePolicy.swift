import Foundation

nonisolated enum UploadFailure: LocalizedError {
    case network(Error)
    case http(Int, retryAfter: TimeInterval?)
    case invalidResponse
    case localRead

    var rejectedHTTPStatus: Int? {
        guard case .http(let status, _) = self, [400, 413, 415, 422].contains(status) else { return nil }
        return status
    }

    var errorDescription: String? {
        switch self {
        case .network(let error): error.localizedDescription
        case .http(let status, _): "сервер вернул HTTP \(status)"
        case .invalidResponse: "сервер вернул ответ неожиданного формата"
        case .localRead: "не удалось прочитать аудиофайл"
        }
    }

    func serverRetryDate(now: Date, itemDelay: TimeInterval) -> Date? {
        switch self {
        case .http(500, _), .invalidResponse:
            // An individual input can trigger this error. Cool down before trying other files.
            return now.addingTimeInterval(2)
        case .http(_, let retryAfter):
            return now.addingTimeInterval(max(itemDelay, retryAfter ?? 0))
        case .network:
            return now.addingTimeInterval(itemDelay)
        case .localRead:
            return nil
        }
    }
}

extension UploadResponse {
    static func uploadResult(data: Data?, response: URLResponse?, error: Error?) -> Result<Self, UploadFailure> {
        if let error { return .failure(.network(error)) }
        guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let retryAfter = seconds.flatMap { $0.isFinite && $0 >= 0 ? min($0, 3600) : nil }
            return .failure(.http(http.statusCode, retryAfter: retryAfter))
        }
        guard let data, let result = try? decodeServerResponse(data) else { return .failure(.invalidResponse) }
        return .success(result)
    }
}

extension PendingFileInfo {
    static func nextUpload(in queue: [Self], at now: Date, serverRetryAfter: Date?) -> (item: Self?, retryAt: Date?) {
        let availableAt = max(now, serverRetryAfter ?? now)
        var nextRetry: Date?
        for file in queue where file.rejectedHTTPStatus == nil {
            let eligibleAt = max(availableAt, file.retryAfter ?? now)
            if eligibleAt <= now { return (file, nil) }
            nextRetry = min(nextRetry ?? eligibleAt, eligibleAt)
        }
        return (nil, nextRetry)
    }
}
