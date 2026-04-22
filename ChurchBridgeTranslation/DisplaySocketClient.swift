import Foundation

actor DisplaySocketClient {
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var currentURL: URL?
    private var churchID = ""
    private var statusHandler: (@Sendable (Bool) -> Void)?
    private var messageHandler: (@Sendable (Data) -> Void)?
    private var errorHandler: (@Sendable (String) -> Void)?

    func setHandlers(
        statusHandler: @escaping @Sendable (Bool) -> Void,
        messageHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: @escaping @Sendable (String) -> Void
    ) {
        self.statusHandler = statusHandler
        self.messageHandler = messageHandler
        self.errorHandler = errorHandler
    }

    func connect(baseURL: URL, churchID: String) async {
        self.currentURL = baseURL
        self.churchID = churchID
        reconnectTask?.cancel()
        await openSocket()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        statusHandler?(false)
    }

    private func openSocket() async {
        guard let currentURL else { return }
        let url = currentURL
            .appending(path: "api")
            .appending(path: "display")
            .appending(path: "v1")
            .appending(queryItems: [URLQueryItem(name: "church_id", value: churchID)])

        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        statusHandler?(true)
        listen(on: task)
    }

    private func listen(on task: URLSessionWebSocketTask) {
        Task {
            do {
                while self.task === task {
                    let message = try await task.receive()
                    switch message {
                    case .string(let string):
                        if let data = string.data(using: .utf8) {
                            messageHandler?(data)
                        }
                    case .data(let data):
                        messageHandler?(data)
                    @unknown default:
                        break
                    }
                }
            } catch {
                let stillActive = self.task === task
                guard stillActive else { return }
                statusHandler?(false)
                errorHandler?("Display feed reconnecting: \(error.localizedDescription)")
                await scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() async {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(2))
            await openSocket()
        }
    }
}
