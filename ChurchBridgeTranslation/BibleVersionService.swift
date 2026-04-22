import Foundation

struct BibleVersionResponse: Decodable {
    let versions: [BibleVersionOption]
}

enum NetworkError: LocalizedError {
    case invalidBaseURL
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid backend base URL."
        case .badResponse(let status):
            return "The backend returned HTTP \(status)."
        }
    }
}

struct BibleVersionService {
    func fetchVersions(baseURL: URL, churchID: String) async throws -> [BibleVersionOption] {
        let endpoint = baseURL
            .appending(path: "api")
            .appending(path: "churches")
            .appending(path: churchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? churchID)
            .appending(path: "bibles")

        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.badResponse(-1) }
        guard 200..<300 ~= http.statusCode else { throw NetworkError.badResponse(http.statusCode) }
        return try JSONDecoder().decode(BibleVersionResponse.self, from: data).versions
    }
}
