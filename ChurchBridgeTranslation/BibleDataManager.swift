import Foundation

/// Manages the on-device bible_ios.sqlite lifecycle.
///
/// Priority order on startup:
///   1. Application Support  — server-downloaded copy (may be newer than bundle)
///   2. App bundle           — always-available fallback shipped with the app
///   3. Server download      — triggered when neither of the above is present
///
/// A background server download also runs silently after finding the bundle copy
/// so future launches pick up the newer version without user intervention.
@MainActor
@Observable
final class BibleDataManager {

    enum DownloadState: Equatable {
        case pending
        case downloading
        case ready
        case failed(String)
    }

    var downloadState: DownloadState = .pending

    var isReady: Bool { downloadState == .ready }

    // MARK: - Paths

    nonisolated static var applicationSupportURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "ChurchBridge/bible_ios.sqlite")
    }

    // MARK: - Lifecycle

    func prepare(baseURL: URL?) async {
        // 1. Previously downloaded copy in Application Support
        if let url = Self.applicationSupportURL,
           FileManager.default.fileExists(atPath: url.path),
           await LocalBibleLibrary.shared.open(at: url) {
            downloadState = .ready
            return
        }

        // 2. Bundled fallback — open immediately, update from server in background
        if let url = Bundle.main.url(forResource: "bible_ios", withExtension: "sqlite"),
           await LocalBibleLibrary.shared.open(at: url) {
            downloadState = .ready
            if let baseURL {
                Task.detached(priority: .background) {
                    await BibleDataManager.silentlyUpdate(from: baseURL)
                }
            }
            return
        }

        // 3. No local copy — must download before the reader can open
        guard let baseURL else {
            downloadState = .failed("Bible data is unavailable. Add a server URL in Settings.")
            return
        }
        downloadState = .downloading
        do {
            let localURL = try await Self.download(from: baseURL)
            if await LocalBibleLibrary.shared.open(at: localURL) {
                downloadState = .ready
            } else {
                downloadState = .failed("Bible database could not be opened after download.")
            }
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    func retry(baseURL: URL?) async {
        downloadState = .pending
        await prepare(baseURL: baseURL)
    }

    // MARK: - Download helpers (nonisolated — runs off the main actor)

    nonisolated private static func download(from baseURL: URL) async throws -> URL {
        let remoteURL = baseURL
            .appending(path: "api")
            .appending(path: "static")
            .appending(path: "bible_ios.sqlite")

        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw NetworkError.badResponse(http.statusCode)
        }

        guard let localURL = applicationSupportURL else {
            throw URLError(.fileDoesNotExist)
        }
        let dir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: localURL)
        return localURL
    }

    nonisolated private static func silentlyUpdate(from baseURL: URL) async {
        guard let _ = applicationSupportURL else { return }
        do {
            _ = try await download(from: baseURL)
        } catch {
            // Non-fatal: bundle copy is already open and working.
        }
    }
}
