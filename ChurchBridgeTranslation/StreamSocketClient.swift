import Foundation

actor StreamSocketClient {
    struct StreamConfiguration: Sendable {
        let url: URL
        let churchID: String
        let sampleRate: Int
        let sourceScriptureVersion: String
        let displayScriptureVersion: String
    }

    private var task: URLSessionWebSocketTask?
    private var state: StreamStatus = .idle
    private var retryTask: Task<Void, Never>?
    private var configuration: StreamConfiguration?
    private var messageHandler: (@Sendable (String) -> Void)?
    private var statusHandler: (@Sendable (StreamStatus) -> Void)?
    private var sessionIDHandler: (@Sendable (Int?) -> Void)?
    private let encoder = JSONEncoder()

    func setHandlers(
        statusHandler: @escaping @Sendable (StreamStatus) -> Void,
        messageHandler: @escaping @Sendable (String) -> Void,
        sessionIDHandler: @escaping @Sendable (Int?) -> Void
    ) {
        self.statusHandler = statusHandler
        self.messageHandler = messageHandler
        self.sessionIDHandler = sessionIDHandler
    }

    func connect(configuration: StreamConfiguration) async {
        self.configuration = configuration
        retryTask?.cancel()
        await openSocket(isReconnect: false)
    }

    func disconnect() async {
        retryTask?.cancel()
        retryTask = nil
        if let task {
            try? await sendEncodable(StreamStopPayload(), over: task)
            task.cancel(with: .normalClosure, reason: nil)
        }
        task = nil
        transition(to: .idle)
    }

    func sendAudio(base64Float32: String) async {
        guard let task else { return }
        do {
            try await sendEncodable(StreamAudioPayload(audio: base64Float32), over: task)
        } catch {
            messageHandler?("Audio send failed: \(error.localizedDescription)")
        }
    }

    private func openSocket(isReconnect: Bool) async {
        guard let configuration else { return }
        let requestURL = configuration.url
            .appending(path: "api")
            .appending(path: "stream")
            .appending(path: "v1")
            .appending(queryItems: [URLQueryItem(name: "church_id", value: configuration.churchID)])

        transition(to: isReconnect ? .reconnecting : .connecting)
        let task = URLSession.shared.webSocketTask(with: requestURL)
        self.task = task
        task.resume()

        do {
            let payload = StreamStartPayload(
                sampleRate: configuration.sampleRate,
                topic: "",
                sourceScriptureVersion: configuration.sourceScriptureVersion,
                displayScriptureVersion: configuration.displayScriptureVersion
            )
            try await sendEncodable(payload, over: task)
            transition(to: .connected)
            listen(on: task)
        } catch {
            messageHandler?("Stream connection failed: \(error.localizedDescription)")
            await scheduleReconnect()
        }
    }

    private func listen(on task: URLSessionWebSocketTask) {
        Task {
            do {
                while self.task === task {
                    let message = try await task.receive()
                    switch message {
                    case .string(let string):
                        await handleInboundString(string)
                    case .data(let data):
                        if let string = String(data: data, encoding: .utf8) {
                            await handleInboundString(string)
                        }
                    @unknown default:
                        break
                    }
                }
            } catch {
                let shouldReconnect = self.state != .idle
                if shouldReconnect {
                    messageHandler?("Stream socket dropped: \(error.localizedDescription)")
                    await scheduleReconnect()
                }
            }
        }
    }

    private func handleInboundString(_ string: String) async {
        guard let data = string.data(using: .utf8) else { return }
        if let started = try? JSONDecoder().decode(StreamSessionStartedEvent.self, from: data),
           started.type == "session_started" {
            sessionIDHandler?(started.sessionId)
            return
        }
        if let error = try? JSONDecoder().decode(ErrorEvent.self, from: data),
           error.type == "error" {
            messageHandler?(error.message)
        }
    }

    private func scheduleReconnect() async {
        guard configuration != nil else { return }
        retryTask?.cancel()
        retryTask = Task {
            transition(to: .reconnecting)
            try? await Task.sleep(for: .seconds(2))
            await openSocket(isReconnect: true)
        }
    }

    private func transition(to nextState: StreamStatus) {
        state = nextState
        statusHandler?(nextState)
    }

    private func sendEncodable<T: Encodable>(_ payload: T, over task: URLSessionWebSocketTask) async throws {
        let data = try encoder.encode(payload)
        guard let string = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(string))
    }
}
