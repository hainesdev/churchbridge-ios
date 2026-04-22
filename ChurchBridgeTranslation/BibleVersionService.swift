import Foundation

struct BibleVersionResponse: Decodable {
    let versions: [BibleVersionOption]
}

struct BibleBook: Identifiable, Decodable, Hashable {
    let bookID: Int
    let bookName: String
    let bookOrder: Int
    let osisID: String
    let testament: String
    let chapterCount: Int

    var id: Int { bookID }

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case bookName = "book_name"
        case bookOrder = "book_order"
        case osisID = "osis_id"
        case testament
        case chapterCount = "chapter_count"
    }
}

struct BibleBooksResponse: Decodable {
    let versionSlug: String
    let books: [BibleBook]

    enum CodingKeys: String, CodingKey {
        case versionSlug = "version_slug"
        case books
    }
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

    func fetchChapter(
        baseURL: URL,
        churchID: String,
        versionSlug: String,
        book: String,
        chapter: Int
    ) async throws -> ScriptureChapter {
        var components = URLComponents(
            url: baseURL
                .appending(path: "api")
                .appending(path: "churches")
                .appending(path: churchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? churchID)
                .appending(path: "bibles")
                .appending(path: versionSlug)
                .appending(path: "chapter"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "book", value: book),
            URLQueryItem(name: "chapter", value: String(chapter)),
        ]

        guard let endpoint = components?.url else { throw NetworkError.invalidBaseURL }

        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.badResponse(-1) }
        guard 200..<300 ~= http.statusCode else { throw NetworkError.badResponse(http.statusCode) }
        return try JSONDecoder().decode(ScriptureChapter.self, from: data)
    }

    func fetchBooks(
        baseURL: URL,
        churchID: String,
        versionSlug: String
    ) async throws -> [BibleBook] {
        let endpoint = baseURL
            .appending(path: "api")
            .appending(path: "churches")
            .appending(path: churchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? churchID)
            .appending(path: "bibles")
            .appending(path: versionSlug)
            .appending(path: "books")

        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.badResponse(-1) }
        guard 200..<300 ~= http.statusCode else { throw NetworkError.badResponse(http.statusCode) }
        return try JSONDecoder().decode(BibleBooksResponse.self, from: data).books
    }
}
