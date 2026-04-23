import SwiftUI
import UIKit

private enum AppTheme {
    static let gradientTop = Color(red: 0.05, green: 0.07, blue: 0.10)
    static let gradientBottom = Color(red: 0.08, green: 0.14, blue: 0.11)
    static let gradientGlow = Color(red: 0.20, green: 0.35, blue: 0.28).opacity(0.30)
    static let newLineEmphasis: Color = Color(red: 0.84, green: 0.94, blue: 1.0)
    static let errorSoft: Color = Color(red: 1.0, green: 0.72, blue: 0.72)
    static let cardBackgroundIdle: Color = .white.opacity(0.08)
    static let cardBorderIdle: Color = .white.opacity(0.06)
    static let textPrimary: Color = .white
    static let textSecondary: Double = 0.78
    static let textTertiary: Double = 0.72
    static let textSpanishFinal: Double = 0.58
    static let textSpanishInterim: Double = 0.52
    static func liveCardBackground(flashed: Bool, pending: Bool) -> Color {
        if flashed { return .white.opacity(0.13) }
        return .white.opacity(pending ? 0.05 : 0.09)
    }
}

struct TranslationTestView: View {
    @Bindable var viewModel: TranslationTestViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasSeenMicOnboarding") private var hasSeenMicOnboarding = false
    @State private var selectedSegment: TranslationSegment?
    @State private var bibleReaderRequest: ChapterReaderRequest?
    @State private var showBibleContents = false
    @State private var scrollToLiveRequested = 0
    @State private var userPinnedToLive = true
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showMicOnboarding = false
    @State private var navBarVisible = true
    @State private var navBarHideTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                background

                Group {
                    if isLive {
                        liveFeed
                    } else {
                        idleCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .navigationTitle("ChurchBridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(navBarVisible ? .visible : .hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                mainControlBar
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsSheet(viewModel: viewModel)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsSheet(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showMicOnboarding) {
                MicOnboardingSheet(
                    onContinue: {
                        hasSeenMicOnboarding = true
                        showMicOnboarding = false
                        Task { await viewModel.start() }
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $selectedSegment) { segment in
                VerseSheet(segment: segment, baseURL: viewModel.settings.apiBaseURL, churchID: viewModel.settings.churchID, settings: viewModel.settings)
            }
            .sheet(item: $bibleReaderRequest) { request in
                ChapterReaderSheet(request: request, baseURL: viewModel.settings.apiBaseURL, churchID: viewModel.settings.churchID, settings: viewModel.settings)
            }
            .sheet(isPresented: $showBibleContents) {
                if let defaultBibleRequest {
                    ChapterReaderSheet(
                        request: defaultBibleRequest,
                        baseURL: viewModel.settings.apiBaseURL,
                        churchID: viewModel.settings.churchID,
                        settings: viewModel.settings,
                        showContentsOnAppear: true
                    )
                }
            }
            .task {
                await viewModel.onAppear()
            }
            .onChange(of: isLive) { _, live in
                if live {
                    registerNavBarAutoHide()
                } else {
                    navBarHideTask?.cancel()
                    navBarVisible = true
                }
            }
        }
    }

    private var mainControlBar: some View {
        HStack(spacing: 14) {
            Button {
                Task {
                    if viewModel.isRunning {
                        await viewModel.stop()
                    } else {
                        requestStartListening()
                    }
                }
            } label: {
                Label(
                    viewModel.isRunning ? "Stop" : "Listen",
                    systemImage: viewModel.isRunning ? "stop.fill" : "play.fill"
                )
                .font(.system(.body, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.large)

            Menu {
                Button {
                    Task { await viewModel.restartDisplayConnection() }
                } label: {
                    Label("Reconnect live text", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    if let lastBibleRequest {
                        bibleReaderRequest = lastBibleRequest
                    } else {
                        showBibleContents = true
                    }
                } label: {
                    Label(lastBibleRequest == nil ? "Browse Bible" : "Resume Bible", systemImage: "book.closed")
                }

                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }

                Button {
                    viewModel.showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }

                Button {
                    showAbout = true
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func requestStartListening() {
        if hasSeenMicOnboarding {
            Task { await viewModel.start() }
        } else {
            showMicOnboarding = true
        }
    }

    private var isLive: Bool {
        viewModel.isRunning || viewModel.streamStatus == .connecting || viewModel.streamStatus == .reconnecting
    }

    private var lastBibleRequest: ChapterReaderRequest? {
        guard
            let versionSlug = viewModel.settings.lastBibleVersionSlug,
            let versionName = viewModel.settings.lastBibleVersionName,
            let book = viewModel.settings.lastBibleBook,
            let chapter = viewModel.settings.lastBibleChapter
        else {
            return nil
        }

        return ChapterReaderRequest(
            versionSlug: versionSlug,
            versionName: versionName,
            book: book,
            chapter: chapter,
            highlightVerse: viewModel.settings.lastBibleVerse
        )
    }

    private var defaultBibleRequest: ChapterReaderRequest? {
        let versionSlug = viewModel.settings.displayScriptureVersion
        let versionName = viewModel.bibleVersions.first(where: { $0.slug == versionSlug })?.name ?? versionSlug.uppercased()
        return ChapterReaderRequest(
            versionSlug: versionSlug,
            versionName: versionName,
            book: "Genesis",
            chapter: 1,
            highlightVerse: nil
        )
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.gradientTop, AppTheme.gradientBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [AppTheme.gradientGlow, .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    private var idleCard: some View {
        Button {
            requestStartListening()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hear the sermon. Follow in English.")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Live Spanish audio is turned into English you can read in real time. Verse links appear when scripture comes up—tap to read or open your Bible there.")
                    .font(.body)
                    .fontDesign(.rounded)
                    .foregroundStyle(.white.opacity(AppTheme.textSecondary))

                Button {
                    showAbout = true
                } label: {
                    Text("Learn more")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 10) {
                    featureRow(icon: "circle.fill", iconColor: .orange, title: "Orange", detail: "Likely quote from this verse.")
                    featureRow(icon: "circle.fill", iconColor: .blue, title: "Blue", detail: "Related passage to explore.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(AppTheme.cardBackgroundIdle, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(AppTheme.cardBorderIdle, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var liveFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    liveStatusStrip
                        .transition(.move(edge: .top).combined(with: .opacity))

                    if viewModel.displayFeed.snapshot.segments.isEmpty, activeSpanish.isEmpty, viewModel.displayFeed.snapshot.partialEnglish.isEmpty {
                        waitingCard
                    }

                    ForEach(viewModel.displayFeed.snapshot.segments) { segment in
                        translationSegmentView(segment: segment)
                            .id(segment.id)
                    }

                    if !viewModel.displayFeed.snapshot.partialEnglish.isEmpty || !activeSpanish.isEmpty {
                        partialCard
                    }

                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottomTrailing) {
                if !userPinnedToLive {
                    Button {
                        userPinnedToLive = true
                        scrollToLiveRequested += 1
                        registerNavBarAutoHide()
                    } label: {
                        Label("Live", systemImage: "arrow.down.to.line")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .foregroundStyle(.white)
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: viewModel.displayFeed.snapshot.lastVisibleSegmentID) { _, _ in
                guard userPinnedToLive else { return }
                scrollLiveToBottom(using: proxy)
            }
            .onChange(of: scrollToLiveRequested) { _, _ in
                scrollLiveToBottom(using: proxy)
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    userPinnedToLive = false
                    registerNavBarAutoHide()
                }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    registerNavBarAutoHide()
                }
            )
        }
    }

    @ViewBuilder
    private func translationSegmentView(segment: TranslationSegment) -> some View {
        let hasVerses = segment.verseDetected != nil || !segment.verseSuggestions.isEmpty
        let isFlashed = !reduceMotion && segment.id == viewModel.displayFeed.snapshot.flashingID
        let englishColor: Color = {
            if reduceMotion { return .white }
            return isFlashed ? AppTheme.newLineEmphasis : .white
        }()
        let borderOpacity: Double = isFlashed ? 0.22 : 0.06

        let content = VStack(alignment: .leading, spacing: 14) {
            Text(segment.english)
                .font(translationTitleFont)
                .foregroundStyle(englishColor)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(segment.spanish)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(AppTheme.textSpanishFinal))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasVerses {
                versePillRow(for: segment)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.liveCardBackground(flashed: isFlashed, pending: segment.pendingCompletion), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(borderOpacity), lineWidth: 1))

        if hasVerses {
            Button {
                selectedSegment = segment
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var translationTitleFont: Font {
        let base = CGFloat(viewModel.settings.translationTextSize)
        let scale = UIFont.preferredFont(forTextStyle: .body).pointSize / 17.0
        let size = min(40, max(20, base * min(scale, 1.35)))
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    private func scrollLiveToBottom(using proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("live-bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("live-bottom", anchor: .bottom) }
        }
    }

    private var liveStatusStrip: some View {
        HStack(spacing: 8) {
            statusPill
            metricChip(title: "Feed", value: viewModel.displayConnected ? "Connected" : "Reconnecting", color: viewModel.displayConnected ? .green : .orange)
            if !viewModel.userFacingLatestError.isEmpty {
                Text(viewModel.userFacingLatestError)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(AppTheme.errorSoft)
                    .lineLimit(2)
            } else if viewModel.diagnostics.clipping {
                metricChip(title: "Input", value: "Clipping", color: .red)
            }
        }
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for speech")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text(waitingHint)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.white.opacity(AppTheme.textTertiary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var partialCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.displayFeed.snapshot.partialEnglish.isEmpty {
                Text("\(viewModel.displayFeed.snapshot.partialEnglish)\u{258C}")
                    .font(translationTitleFont)
                    .foregroundStyle(.white.opacity(0.78))
            }
            if !activeSpanish.isEmpty {
                Text(activeSpanish)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(AppTheme.textSpanishInterim))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func registerNavBarAutoHide() {
        navBarVisible = true
        guard isLive else { return }
        navBarHideTask?.cancel()
        navBarHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, isLive else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                navBarVisible = false
            }
        }
    }

    private func versePillRow(for segment: TranslationSegment) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let verse = segment.verseDetected {
                    verseTag(title: verse.reference, tint: .orange)
                }
                ForEach(segment.verseSuggestions, id: \.reference) { suggestion in
                    verseTag(title: suggestion.reference, tint: .blue)
                }
            }
        }
    }

    private var statusPill: some View {
        let color: Color
        let text: String
        switch viewModel.streamStatus {
        case .idle: color = .gray; text = "Idle"
        case .connecting: color = .blue; text = "Connecting"
        case .connected: color = .green; text = "Live"
        case .reconnecting: color = .orange; text = "Reconnecting"
        case .failed: color = .red; text = "Error"
        }

        return Label(text, systemImage: "waveform")
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func metricChip(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(Font.caption2.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func verseTag(title: String, tint: Color) -> some View {
        let label = Text(title)
            .font(.system(.caption, design: .rounded, weight: .bold))

        return label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func featureRow(icon: String, iconColor: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
            }
        }
    }

    private var waitingHint: String {
        if viewModel.diagnostics.clipping { return "Audio is a bit too loud. Move back from the speaker or lower the volume." }
        if viewModel.diagnostics.rmsLevel < 0.015 { return "Hard to hear the service. Move closer to the speaker or sound system." }
        if let lastInterimAt = viewModel.displayFeed.snapshot.lastInterimAt, viewModel.displayFeed.snapshot.lastFinalAt == nil, Date().timeIntervalSince(lastInterimAt) > 6 {
            return "We’re still catching phrases—this can take a few seconds in noisy rooms."
        }
        if viewModel.displayFeed.snapshot.lastFinalAt != nil && viewModel.displayFeed.snapshot.lastTranslationAt == nil {
            return "Heard Spanish; waiting for the English to appear."
        }
        if let lastFinalAt = viewModel.displayFeed.snapshot.lastFinalAt, let lastTranslationAt = viewModel.displayFeed.snapshot.lastTranslationAt, lastTranslationAt < lastFinalAt, Date().timeIntervalSince(lastFinalAt) > 6 {
            return "Translation is a little behind. It should catch up shortly."
        }
        return "Listening for speech…"
    }

    private var activeSpanish: String {
        let lines = viewModel.displayFeed.snapshot.spanishLines.joined(separator: " ")
        if lines.isEmpty { return viewModel.displayFeed.snapshot.partialSpanish }
        if viewModel.displayFeed.snapshot.partialSpanish.isEmpty { return lines }
        return "\(lines) \(viewModel.displayFeed.snapshot.partialSpanish)"
    }
}

private struct MicOnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Microphone & live audio")
                    .font(.title2)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                Text("ChurchBridge uses your microphone to hear the service while you read the English text. Only audio you choose to send is streamed to the server you configure in Settings—typically your church’s ChurchBridge endpoint.")
                    .font(.body)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Agree and start listening", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Before you listen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Not now") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Section {
                        Text("Version \(v) (\(b))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("What ChurchBridge does") {
                    Text("ChurchBridge is more than a translator. It helps carry the emotion, emphasis, and meaning of a live sermon across languages while you read along.")
                    Text("As the speaker talks, the app writes the English translation in real time and enriches key moments with likely scripture references.")
                }

                Section("Verse pills") {
                    Text("Orange pills mark the verse most likely being quoted or directly referenced.")
                    Text("Blue pills mark nearby passages that may help you follow the message more deeply.")
                }

                Section("Reading scripture") {
                    Text("Tap any pill to see the explanation and compare the passage in Spanish and English.")
                    Text("From there, open the full Bible at that exact verse and keep reading forward.")
                }
            }
            .navigationTitle("About")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SettingsSheet: View {
    @Bindable var viewModel: TranslationTestViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Base URL", text: $viewModel.settings.baseURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    TextField("Church ID", text: $viewModel.settings.churchID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Bible Versions") {
                    if viewModel.bibleVersions.isEmpty {
                        Text(viewModel.bibleVersionsError.isEmpty ? "No versions loaded yet." : viewModel.bibleVersionsError)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Spanish", selection: $viewModel.settings.sourceScriptureVersion) {
                            ForEach(viewModel.bibleVersions) { version in
                                Text("\(version.name) (\(version.slug))").tag(version.slug)
                            }
                        }

                        Picker("English", selection: $viewModel.settings.displayScriptureVersion) {
                            ForEach(viewModel.bibleVersions) { version in
                                Text("\(version.name) (\(version.slug))").tag(version.slug)
                            }
                        }
                    }

                    Button("Reload Bible Versions") {
                        Task { await viewModel.loadBibleVersions() }
                    }
                }

                Section("Audio Mode") {
                    Picker("Mode", selection: $viewModel.settings.captureMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text("Live capture uses Apple Voice Passthrough. Advanced diagnostics stay in the waveform panel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Reading") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Translation Size")
                            Spacer()
                            Text("\(Int(viewModel.settings.translationTextSize.rounded())) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $viewModel.settings.translationTextSize, in: 20...32, step: 1)
                        Text("This controls the size of the live English translation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Section {
                        Text("ChurchBridge \(v) (\(b))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct DiagnosticsSheet: View {
    @Bindable var viewModel: TranslationTestViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    if !viewModel.userFacingLatestError.isEmpty {
                        LabeledContent("Error (in app)", value: viewModel.userFacingLatestError)
                    }
                    LabeledContent("Stream", value: viewModel.streamStatus.rawValue.capitalized)
                    LabeledContent("Display Feed", value: viewModel.displayConnected ? "Connected" : "Disconnected")
                    LabeledContent("Input Route", value: viewModel.diagnostics.routeName)
                    LabeledContent("Capture Path", value: viewModel.diagnostics.capturePath)
                }

                if !viewModel.latestError.isEmpty {
                    Section("Error (raw)") {
                        Text(viewModel.latestError)
                            .font(.system(.caption, design: .monospaced))
                    }
                }

                Section("Audio") {
                    LabeledContent("Input Sample Rate", value: "\(Int(viewModel.diagnostics.inputSampleRate)) Hz")
                    LabeledContent("Emitted Sample Rate", value: "\(Int(viewModel.diagnostics.emittedSampleRate)) Hz")
                    LabeledContent("Chunk Size", value: "\(viewModel.diagnostics.chunkSampleCount) samples")
                    LabeledContent("Input Format", value: viewModel.diagnostics.inputFormatDescription)
                    LabeledContent("Input Level", value: "\(Int((viewModel.diagnostics.rmsLevel * 100).rounded()))%")
                    LabeledContent("Speech Activity", value: viewModel.diagnostics.speechDetected ? "Detected" : "Idle")
                    LabeledContent("Voice Processing", value: viewModel.diagnostics.voiceProcessingEnabled ? "Enabled" : "Off")
                    LabeledContent("Echo-Cancelled Input", value: viewModel.diagnostics.echoCancelledInputEnabled ? "Enabled" : "Off")
                }

                Section("Transport") {
                    LabeledContent("Chunks Emitted", value: "\(viewModel.interpreterChunksObserved)")
                    LabeledContent("Chunks Sent", value: "\(viewModel.interpreterChunksSent)")
                    LabeledContent("Send Failures", value: "\(viewModel.interpreterSendFailures)")
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct VerseSheetItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case detected
        case suggested
    }

    let kind: Kind
    let reference: String
    let explanation: String
    let sourcePassage: ScripturePassage?
    let displayPassage: ScripturePassage?

    var id: String { "\(reference)-\(badgeText)" }

    var badgeText: String {
        switch kind {
        case .detected:
            return "Detected"
        case .suggested:
            return "Suggested"
        }
    }
}

private struct ChapterReaderRequest: Identifiable, Equatable {
    let versionSlug: String
    let versionName: String
    let book: String
    let chapter: Int
    let highlightVerse: Int?

    var id: String { "\(versionSlug)-\(book)-\(chapter)-\(highlightVerse ?? 0)" }
}

private struct LoadedBibleChapter: Identifiable, Equatable {
    let request: ChapterReaderRequest
    let chapter: ScriptureChapter

    var id: String { "\(request.book)-\(request.chapter)" }
}

// MARK: - Bible reader scroll (chapter frames for nav title)
private struct BibleChapterFrame: Equatable {
    let id: String
    var minY: CGFloat
    var maxY: CGFloat
}

private struct BibleChapterFrameKey: PreferenceKey {
    static var defaultValue: [BibleChapterFrame] = []
    static func reduce(value: inout [BibleChapterFrame], nextValue: () -> [BibleChapterFrame]) {
        for f in nextValue() {
            if let i = value.firstIndex(where: { $0.id == f.id }) {
                value[i] = f
            } else {
                value.append(f)
            }
        }
    }
}

/// Coarse distance zones to avoid firing scroll actions every frame (seamless prefetch).
private struct BibleScrollPrefetchSignal: Equatable {
    var nearEnd: Int
    var nearStart: Int
}

private struct BibleChapterReadProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        let p = max(0, min(1, configuration.fractionCompleted ?? 0))
        return GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: w * p)
            }
        }
        .frame(height: 2)
    }
}

private func scrollGeometryVerticalOffset(_ g: ScrollGeometry) -> CGFloat {
    g.contentOffset.y
}

private struct VerseSheet: View {
    let segment: TranslationSegment
    let baseURL: URL?
    let churchID: String
    let settings: SettingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemID: String
    @State private var chapterRequest: ChapterReaderRequest?

    private let cardInk = Color.black.opacity(0.88)
    private let cardSecondaryInk = Color.black.opacity(0.62)
    private let chipInk = Color(red: 0.13, green: 0.13, blue: 0.15)

    init(segment: TranslationSegment, baseURL: URL?, churchID: String, settings: SettingsStore) {
        self.segment = segment
        self.baseURL = baseURL
        self.churchID = churchID
        self.settings = settings

        let defaultID: String
        if let verse = segment.verseDetected {
            defaultID = "\(verse.reference)-Detected"
        } else if let suggestion = segment.verseSuggestions.first {
            defaultID = "\(suggestion.reference)-Suggested"
        } else {
            defaultID = "empty"
        }
        _selectedItemID = State(initialValue: defaultID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if items.count > 1 {
                        selectionChips
                    }

                    if let selectedItem {
                        heroCard(for: selectedItem)

                        if let sourcePassage = selectedItem.sourcePassage {
                            passageCard(
                                title: sourcePassage.version.name,
                                languageLabel: "Spanish",
                                passage: sourcePassage,
                                accent: .orange
                            )
                        }

                        if let displayPassage = selectedItem.displayPassage {
                            passageCard(
                                title: displayPassage.version.name,
                                languageLabel: "English",
                                passage: displayPassage,
                                accent: .blue
                            )
                        }

                        if selectedItem.sourcePassage == nil, selectedItem.displayPassage == nil {
                            unavailablePassageCard
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Scripture")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $chapterRequest) { request in
                ChapterReaderSheet(request: request, baseURL: baseURL, churchID: churchID, settings: settings)
            }
        }
    }

    private var items: [VerseSheetItem] {
        var values: [VerseSheetItem] = []
        if let verse = segment.verseDetected {
            values.append(
                VerseSheetItem(
                    kind: .detected,
                    reference: verse.reference,
                    explanation: verse.explanation ?? "This appears to be the strongest scripture match for the current caption.",
                    sourcePassage: verse.sourcePassage,
                    displayPassage: verse.displayPassage
                )
            )
        }
        values.append(contentsOf: segment.verseSuggestions.map {
            VerseSheetItem(
                kind: .suggested,
                reference: $0.reference,
                explanation: $0.explanation ?? $0.relevanceNote,
                sourcePassage: $0.sourcePassage,
                displayPassage: $0.displayPassage
            )
        })
        return values
    }

    private var selectedItem: VerseSheetItem? {
        items.first(where: { $0.id == selectedItemID }) ?? items.first
    }

    private var selectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        selectedItemID = item.id
                    } label: {
                        Text(item.reference)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(chipFill(for: item), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(chipForeground(for: item))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func heroCard(for item: VerseSheetItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.reference)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundColor(cardInk)
            Text(item.explanation)
                .font(.system(.body, design: .rounded))
                .foregroundColor(cardSecondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func passageCard(title: String, languageLabel: String, passage: ScripturePassage, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(languageLabel.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundColor(cardInk)
                    Text(passage.reference)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(cardSecondaryInk)
                }

                Spacer()

                Button("Open in Bible") {
                    chapterRequest = ChapterReaderRequest(
                        versionSlug: passage.version.slug,
                        versionName: passage.version.name,
                        book: passage.book,
                        chapter: passage.chapter,
                        highlightVerse: passage.verseStart
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(accent)
            }

            Text("Continue reading from \(passage.reference) in \(languageLabel).")
                .font(.system(.footnote, design: .rounded))
                .foregroundColor(cardSecondaryInk)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(passage.verses, id: \.reference) { verse in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(verse.verse)")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(accent)
                            .frame(width: 28, alignment: .leading)
                        Text(verse.text)
                            .font(.system(.body, design: .rounded))
                            .foregroundColor(cardInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var unavailablePassageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Passage text is still loading")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundColor(cardInk)
            Text("The reference and explanation are available, but the full passage text has not arrived yet. Try reopening this verse in a moment.")
                .font(.system(.body, design: .rounded))
                .foregroundColor(cardSecondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func chipFill(for item: VerseSheetItem) -> Color {
        let tint: Color = item.kind == .detected ? .orange : .blue
        return selectedItemID == item.id ? tint.opacity(0.18) : .white
    }

    private func chipForeground(for item: VerseSheetItem) -> Color {
        selectedItemID == item.id ? (item.kind == .detected ? .orange : .blue) : chipInk
    }
}

private struct ChapterReaderSheet: View {
    let request: ChapterReaderRequest
    let baseURL: URL?
    let churchID: String
    let settings: SettingsStore
    let showContentsOnAppear: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceReaderMotion
    @State private var currentRequest: ChapterReaderRequest
    @State private var loadedChapters: [LoadedBibleChapter] = []
    @State private var books: [BibleBook] = []
    @State private var errorMessage = ""
    @State private var isLoading = true
    @State private var isLoadingPrevious = false
    @State private var isLoadingNext = false
    @State private var showTableOfContents = false
    @State private var shouldPersistLocation = true
    @State private var canPrefetchOnScroll = false
    @State private var chapterFrameHints: [BibleChapterFrame] = []
    @State private var scrollY: CGFloat = 0
    @State private var lastChapterFetchTime: Date = .distantPast

    private let service = BibleVersionService()
    private let maxLoadedChapters = 5
    private let cardInk = Color.black.opacity(0.88)
    private let cardSecondaryInk = Color.black.opacity(0.62)
    private let chapterFetchCooldown: TimeInterval = 0.35
    private let seamlessPrefetchDistance: CGFloat = 900
    private let focalLineFromTop: CGFloat = 108

    private var verseCardPadding: CGFloat {
        if dynamicTypeSize >= .accessibility1 {
            return 20
        }
        return 18
    }

    private var verseRowVerticalPadding: CGFloat {
        if dynamicTypeSize >= .accessibility1 {
            return 12
        }
        return 10
    }

    init(request: ChapterReaderRequest, baseURL: URL?, churchID: String, settings: SettingsStore, showContentsOnAppear: Bool = false) {
        self.request = request
        self.baseURL = baseURL
        self.churchID = churchID
        self.settings = settings
        self.showContentsOnAppear = showContentsOnAppear
        _currentRequest = State(initialValue: request)
        _shouldPersistLocation = State(initialValue: !showContentsOnAppear)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading \(currentRequest.book) \(currentRequest.chapter)...")
                } else if !loadedChapters.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                if isLoadingPrevious {
                                    previousChapterLoadingBlock
                                }

                                ForEach(Array(loadedChapters.enumerated()), id: \.1.id) { index, loaded in
                                    if index > 0 {
                                        chapterSeamBetweenCards
                                    }
                                    chapterSection(for: loaded)
                                }

                                if isLoadingNext {
                                    nextChapterLoadingBlock
                                }
                            }
                            .padding(16)
                            .coordinateSpace(name: "bibleScroll")
                            .onPreferenceChange(BibleChapterFrameKey.self) { frames in
                                chapterFrameHints = frames
                                updateCurrentChapterForScrollPosition()
                            }
                        }
                        .onScrollGeometryChange(for: Int.self) { geo in
                            Int((scrollGeometryVerticalOffset(geo) + 2) / 6)
                        } action: { _, bucket in
                            scrollY = CGFloat(bucket) * 6.0
                            updateCurrentChapterForScrollPosition()
                        }
                        .onScrollGeometryChange(for: BibleScrollPrefetchSignal.self) { geo in
                            let (dStart, dEnd) = scrollDistancesToEdges(geo)
                            return BibleScrollPrefetchSignal(
                                nearEnd: Int(max(0, dEnd) / seamlessPrefetchDistance),
                                nearStart: Int(max(0, dStart) / seamlessPrefetchDistance)
                            )
                        } action: { old, new in
                            if !canPrefetchOnScroll { return }
                            let ok = Date().timeIntervalSince(lastChapterFetchTime) >= chapterFetchCooldown
                            if ok, old.nearEnd > 0, new.nearEnd == 0 {
                                considerAppendNextChapter()
                            } else if ok, old.nearStart > 0, new.nearStart == 0 {
                                considerPrependPreviousChapter()
                            }
                        }
                        .onAppear {
                            Task {
                                try? await Task.sleep(for: .milliseconds(180))
                                canPrefetchOnScroll = true
                            }
                            scrollToHighlight(using: proxy)
                        }
                        .onChange(of: currentRequest.id) { _, _ in
                            scrollToHighlight(using: proxy)
                        }
                        .onChange(of: isLoadingPrevious) { wasLoading, isLoading in
                            if wasLoading, !isLoading {
                                reanchorScrollAfterPrepend(using: proxy)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "Chapter unavailable",
                            systemImage: "book.closed",
                            description: Text(errorMessage.isEmpty ? "We couldn't load this chapter right now." : errorMessage)
                        )
                        if !errorMessage.isEmpty {
                            Button("Try again") {
                                isLoading = true
                                errorMessage = ""
                                Task { await loadChapter() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .task {
                await loadChapter()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 4) {
                        Text(navigationBarChapterTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let p = focusedChapterReadProgress {
                            ProgressView(value: p, total: 1) {}
                                .labelsHidden()
                                .progressViewStyle(BibleChapterReadProgressStyle())
                                .frame(height: 2)
                                .frame(maxWidth: 200)
                        }
                    }
                    .contextMenu {
                        Button {
                            copyCurrentReferenceToPasteboard()
                        } label: {
                            Label("Copy reference", systemImage: "doc.on.doc")
                        }
                        Button {
                            showTableOfContents = true
                        } label: {
                            Label("Open contents", systemImage: "list.bullet")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens a menu to copy the reference or open contents")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showTableOfContents = true
                    } label: {
                        Label("Contents", systemImage: "list.bullet")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showTableOfContents) {
                BibleContentsSheet(books: books, currentRequest: currentRequest) { request in
                    Task { await jumpTo(request: request) }
                }
            }
        }
    }

    private var navigationBarChapterTitle: String {
        "\(currentRequest.book) \(currentRequest.chapter)"
    }

    /// Read progress for the chapter currently reflected in the title (and loaded).
    private var focusedChapterReadProgress: CGFloat? {
        guard let loaded = loadedChapters.first(where: {
            $0.request.book == currentRequest.book && $0.request.chapter == currentRequest.chapter
        }) else { return nil }
        return readProgressInFocusedChapter(loaded)
    }

    private var previousChapterLoadingBlock: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading previous chapter…")
                .font(.subheadline)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var nextChapterLoadingBlock: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading next chapter…")
                .font(.subheadline)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var chapterSeamBetweenCards: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .frame(maxWidth: .infinity)
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private func readProgressInFocusedChapter(_ loaded: LoadedBibleChapter) -> CGFloat? {
        let focalY = scrollY + focalLineFromTop
        guard let f = chapterFrameHints.first(where: { $0.id == loaded.id }) else { return nil }
        let height = f.maxY - f.minY
        guard height > 2, focalY >= f.minY - 2, focalY <= f.maxY + 2 else { return nil }
        let y = min(f.maxY, max(f.minY, focalY))
        return (y - f.minY) / height
    }

    private func copyCurrentReferenceToPasteboard() {
        UIPasteboard.general.string = currentReferenceStringForCopy()
    }

    private func currentReferenceStringForCopy() -> String {
        if let v = currentRequest.highlightVerse {
            return "\(currentRequest.book) \(currentRequest.chapter):\(v)"
        }
        return "\(currentRequest.book) \(currentRequest.chapter)"
    }

    private func reanchorScrollAfterPrepend(using proxy: ScrollViewProxy) {
        if let h = currentRequest.highlightVerse {
            let id = verseRowScrollID(book: currentRequest.book, chapter: currentRequest.chapter, verse: h)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if self.reduceReaderMotion {
                    proxy.scrollTo(id, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        } else if let loaded = loadedChapters.first(where: {
            $0.request.book == currentRequest.book && $0.request.chapter == currentRequest.chapter
        }), let v = loaded.chapter.verses.map(\.verse).min() {
            let id = verseRowScrollID(book: currentRequest.book, chapter: currentRequest.chapter, verse: v)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if self.reduceReaderMotion {
                    proxy.scrollTo(id, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    private func scrollDistancesToEdges(_ g: ScrollGeometry) -> (start: CGFloat, end: CGFloat) {
        let y = scrollGeometryVerticalOffset(g)
        let ch = g.contentSize.height
        let ti = g.contentInsets.top
        let bi = g.contentInsets.bottom
        var vh = g.containerSize.height
        if vh < 1, ch > 0 { vh = min(ch, 800) }
        if vh < 1 { return (0, 0) }
        let dStart = y - ti
        let dEnd = ch - bi - y - vh
        return (dStart, dEnd)
    }

    private func considerPrependPreviousChapter() {
        guard canPrefetchOnScroll, !isLoading, !isLoadingPrevious, !isLoadingNext, books.count > 0,
              let p = previousRequest
        else { return }
        guard !loadedChapters.contains(where: { $0.request.book == p.book && $0.request.chapter == p.chapter })
        else { return }
        lastChapterFetchTime = Date()
        Task { await prependChapter(p) }
    }

    private func considerAppendNextChapter() {
        guard canPrefetchOnScroll, !isLoading, !isLoadingPrevious, !isLoadingNext, books.count > 0,
              let n = nextRequest
        else { return }
        guard !loadedChapters.contains(where: { $0.request.book == n.book && $0.request.chapter == n.chapter })
        else { return }
        lastChapterFetchTime = Date()
        Task { await appendChapter(n) }
    }

    private func postLoadPrefetchNeighbors(allowPrepend: Bool = true) async {
        guard loadedChapters.count == 1, let only = loadedChapters.first, books.count > 0 else { return }
        if allowPrepend, let p = request(before: only.request), !loadedChapters.contains(where: { $0.request.book == p.book && $0.request.chapter == p.chapter }) {
            await prependChapter(p)
        }
        if let n = request(after: only.request), !loadedChapters.contains(where: { $0.request.book == n.book && $0.request.chapter == n.chapter }) {
            await appendChapter(n)
        }
    }

    private func updateCurrentChapterForScrollPosition() {
        guard !loadedChapters.isEmpty, !chapterFrameHints.isEmpty else { return }
        let focalY = scrollY + focalLineFromTop
        guard
            let best = chapterFrameHints.first(where: { $0.minY - 0.5 <= focalY && focalY < $0.maxY + 0.5 }),
            let match = loadedChapters.first(where: { $0.id == best.id })
        else { return }
        let next = match.request
        if next.book != currentRequest.book || next.chapter != currentRequest.chapter {
            currentRequest = ChapterReaderRequest(
                versionSlug: next.versionSlug,
                versionName: next.versionName,
                book: next.book,
                chapter: next.chapter,
                highlightVerse: next.highlightVerse
            )
            if shouldPersistLocation {
                persistLocation(for: currentRequest)
            }
        }
    }

    private func loadChapter() async {
        guard let baseURL else {
            errorMessage = "Missing backend base URL."
            isLoading = false
            return
        }

        do {
            async let booksResponse = service.fetchBooks(
                baseURL: baseURL,
                churchID: churchID,
                versionSlug: currentRequest.versionSlug
            )
            async let chapterResponse = service.fetchChapter(
                baseURL: baseURL,
                churchID: churchID,
                versionSlug: currentRequest.versionSlug,
                book: currentRequest.book,
                chapter: currentRequest.chapter
            )
            let (fetchedBooks, chapter) = try await (booksResponse, chapterResponse)
            books = fetchedBooks
            loadedChapters = [LoadedBibleChapter(request: currentRequest, chapter: chapter)]
            if shouldPersistLocation {
                persistLocation(for: currentRequest)
            }
            if showContentsOnAppear {
                showTableOfContents = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        if errorMessage.isEmpty, loadedChapters.count == 1, currentRequest.highlightVerse == nil {
            Task { await postLoadPrefetchNeighbors(allowPrepend: true) }
        }
    }

    private var currentBookIndex: Int? {
        books.firstIndex(where: { $0.bookName == currentRequest.book })
    }

    private var previousChapterRequest: ChapterReaderRequest? {
        guard let currentBookIndex else { return nil }
        if currentRequest.chapter > 1 {
            return ChapterReaderRequest(versionSlug: currentRequest.versionSlug, versionName: currentRequest.versionName, book: currentRequest.book, chapter: currentRequest.chapter - 1, highlightVerse: nil)
        }
        guard currentBookIndex > 0 else { return nil }
        let previousBook = books[currentBookIndex - 1]
        return ChapterReaderRequest(versionSlug: currentRequest.versionSlug, versionName: currentRequest.versionName, book: previousBook.bookName, chapter: previousBook.chapterCount, highlightVerse: nil)
    }

    private var nextChapterRequest: ChapterReaderRequest? {
        guard let currentBookIndex else { return nil }
        let currentBook = books[currentBookIndex]
        if currentRequest.chapter < currentBook.chapterCount {
            return ChapterReaderRequest(versionSlug: currentRequest.versionSlug, versionName: currentRequest.versionName, book: currentRequest.book, chapter: currentRequest.chapter + 1, highlightVerse: nil)
        }
        guard currentBookIndex + 1 < books.count else { return nil }
        let nextBook = books[currentBookIndex + 1]
        return ChapterReaderRequest(versionSlug: currentRequest.versionSlug, versionName: currentRequest.versionName, book: nextBook.bookName, chapter: 1, highlightVerse: nil)
    }

    private func verseRowScrollID(book: String, chapter: Int, verse: Int) -> String {
        "\(book) \(chapter):\(verse)"
    }

    private func scrollToHighlight(using proxy: ScrollViewProxy) {
        guard let highlightVerse = currentRequest.highlightVerse else { return }
        let id: String
        if let loaded = loadedChapters.first(where: { $0.request.book == currentRequest.book && $0.request.chapter == currentRequest.chapter }) {
            id = verseRowScrollID(book: loaded.chapter.book, chapter: loaded.chapter.chapter, verse: highlightVerse)
        } else {
            id = verseRowScrollID(book: currentRequest.book, chapter: currentRequest.chapter, verse: highlightVerse)
        }
        func go(deadline: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
                if self.reduceReaderMotion {
                    proxy.scrollTo(id, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        go(deadline: 0.12)
        go(deadline: 0.4)
        go(deadline: 0.75)
    }

    private func chapterSection(for loaded: LoadedBibleChapter) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loaded.chapter.reference)
                    .font(.title2)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .foregroundColor(cardInk)
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(loaded.chapter.verses, id: \.verse) { verse in
                    verseRow(loaded: loaded, verse: verse)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(verseCardPadding)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            GeometryReader { proxy in
                let f = proxy.frame(in: .named("bibleScroll"))
                Color.clear.preference(
                    key: BibleChapterFrameKey.self,
                    value: [BibleChapterFrame(id: loaded.id, minY: f.minY, maxY: f.maxY)]
                )
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func verseRow(loaded: LoadedBibleChapter, verse: ScripturePassageVerse) -> some View {
        let isHighlighted = (loaded.request.highlightVerse.map { $0 == verse.verse } ?? false)
            && loaded.request.book == currentRequest.book
            && loaded.request.chapter == currentRequest.chapter
        HStack(alignment: .top, spacing: 12) {
            Text("\(verse.verse)")
                .font(.headline)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(isHighlighted ? Color.accentColor : cardSecondaryInk)
                .frame(minWidth: 28, idealWidth: 34, alignment: .leading)
            Text(verse.text)
                .font(.body)
                .fontDesign(.rounded)
                .foregroundColor(cardInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verseRowVerticalPadding)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isHighlighted
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.accentColor.opacity(0.42) : .clear,
                    lineWidth: isHighlighted ? 1.5 : 0
                )
        }
        .id(verseRowScrollID(book: loaded.chapter.book, chapter: loaded.chapter.chapter, verse: verse.verse))
    }

    private func prependChapter(_ request: ChapterReaderRequest) async {
        guard let baseURL else { return }
        guard !loadedChapters.contains(where: { $0.request.book == request.book && $0.request.chapter == request.chapter }) else { return }
        isLoadingPrevious = true
        defer { isLoadingPrevious = false }
        do {
            let chapter = try await service.fetchChapter(
                baseURL: baseURL,
                churchID: churchID,
                versionSlug: request.versionSlug,
                book: request.book,
                chapter: request.chapter
            )
            loadedChapters.insert(LoadedBibleChapter(request: request, chapter: chapter), at: 0)
            trimLoadedChapters(keeping: currentRequest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendChapter(_ request: ChapterReaderRequest) async {
        guard let baseURL else { return }
        guard !loadedChapters.contains(where: { $0.request.book == request.book && $0.request.chapter == request.chapter }) else { return }
        isLoadingNext = true
        defer { isLoadingNext = false }
        do {
            let chapter = try await service.fetchChapter(
                baseURL: baseURL,
                churchID: churchID,
                versionSlug: request.versionSlug,
                book: request.book,
                chapter: request.chapter
            )
            loadedChapters.append(LoadedBibleChapter(request: request, chapter: chapter))
            trimLoadedChapters(keeping: currentRequest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func jumpTo(request: ChapterReaderRequest) async {
        guard let baseURL else { return }
        showTableOfContents = false
        isLoading = true
        errorMessage = ""
        shouldPersistLocation = true
        canPrefetchOnScroll = false
        currentRequest = request
        do {
            let chapter = try await service.fetchChapter(
                baseURL: baseURL,
                churchID: churchID,
                versionSlug: request.versionSlug,
                book: request.book,
                chapter: request.chapter
            )
            loadedChapters = [LoadedBibleChapter(request: request, chapter: chapter)]
            persistLocation(for: request)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        if errorMessage.isEmpty, loadedChapters.count == 1, currentRequest.highlightVerse == nil {
            Task { await postLoadPrefetchNeighbors(allowPrepend: true) }
        }
    }

    private func persistLocation(for request: ChapterReaderRequest) {
        settings.saveBibleLocation(
            versionSlug: request.versionSlug,
            versionName: request.versionName,
            book: request.book,
            chapter: request.chapter,
            verse: request.highlightVerse
        )
    }

    private func trimLoadedChapters(keeping request: ChapterReaderRequest) {
        guard loadedChapters.count > maxLoadedChapters else { return }
        while loadedChapters.count > maxLoadedChapters {
            guard let currentIndex = loadedChapters.firstIndex(where: {
                $0.request.book == request.book && $0.request.chapter == request.chapter
            }) else {
                loadedChapters.removeFirst()
                continue
            }

            let distanceToStart = currentIndex
            let distanceToEnd = loadedChapters.count - currentIndex - 1

            if distanceToStart > distanceToEnd {
                loadedChapters.removeFirst()
            } else {
                loadedChapters.removeLast()
            }
        }
    }

    private var previousRequest: ChapterReaderRequest? {
        guard let first = loadedChapters.first else { return nil }
        return request(before: first.request)
    }

    private var nextRequest: ChapterReaderRequest? {
        guard let last = loadedChapters.last else { return nil }
        return request(after: last.request)
    }

    private func request(before request: ChapterReaderRequest) -> ChapterReaderRequest? {
        guard let currentBookIndex = books.firstIndex(where: { $0.bookName == request.book }) else { return nil }
        if request.chapter > 1 {
            return ChapterReaderRequest(versionSlug: request.versionSlug, versionName: request.versionName, book: request.book, chapter: request.chapter - 1, highlightVerse: nil)
        }
        guard currentBookIndex > 0 else { return nil }
        let previousBook = books[currentBookIndex - 1]
        return ChapterReaderRequest(versionSlug: request.versionSlug, versionName: request.versionName, book: previousBook.bookName, chapter: previousBook.chapterCount, highlightVerse: nil)
    }

    private func request(after request: ChapterReaderRequest) -> ChapterReaderRequest? {
        guard let currentBookIndex = books.firstIndex(where: { $0.bookName == request.book }) else { return nil }
        let currentBook = books[currentBookIndex]
        if request.chapter < currentBook.chapterCount {
            return ChapterReaderRequest(versionSlug: request.versionSlug, versionName: request.versionName, book: request.book, chapter: request.chapter + 1, highlightVerse: nil)
        }
        guard currentBookIndex + 1 < books.count else { return nil }
        let nextBook = books[currentBookIndex + 1]
        return ChapterReaderRequest(versionSlug: request.versionSlug, versionName: request.versionName, book: nextBook.bookName, chapter: 1, highlightVerse: nil)
    }
}

private struct BibleContentsSheet: View {
    let books: [BibleBook]
    let currentRequest: ChapterReaderRequest
    let onSelect: (ChapterReaderRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showBookPicker = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentRequest.book)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundColor(.black.opacity(0.88))
                    Text("\(selectedBook?.chapterCount ?? 0) chapters")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(.black.opacity(0.62))
                    Text(currentRequest.versionName)
                        .font(.caption)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                Divider()

                if let selectedBook {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 12)], spacing: 12) {
                            ForEach(1...selectedBook.chapterCount, id: \.self) { chapter in
                                Button {
                                    onSelect(
                                        ChapterReaderRequest(
                                            versionSlug: currentRequest.versionSlug,
                                            versionName: currentRequest.versionName,
                                            book: selectedBook.bookName,
                                            chapter: chapter,
                                            highlightVerse: nil
                                        )
                                    )
                                    dismiss()
                                } label: {
                                    Text("\(chapter)")
                                        .font(.system(.body, design: .rounded, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(chapterFill(for: selectedBook, chapter: chapter), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .foregroundStyle(chapterForeground(for: selectedBook, chapter: chapter))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Contents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showBookPicker = true
                    } label: {
                        Label("Book", systemImage: "books.vertical")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showBookPicker) {
                BibleBookPickerSheet(books: books, currentRequest: currentRequest) { book in
                    showBookPicker = false
                    onSelect(
                        ChapterReaderRequest(
                            versionSlug: currentRequest.versionSlug,
                            versionName: currentRequest.versionName,
                            book: book.bookName,
                            chapter: 1,
                            highlightVerse: nil
                        )
                    )
                    dismiss()
                }
            }
        }
    }

    private var selectedBook: BibleBook? {
        books.first(where: { $0.bookName == currentRequest.book }) ?? books.first
    }

    private func chapterFill(for book: BibleBook, chapter: Int) -> Color {
        book.bookName == currentRequest.book && chapter == currentRequest.chapter ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground)
    }

    private func chapterForeground(for book: BibleBook, chapter: Int) -> Color {
        book.bookName == currentRequest.book && chapter == currentRequest.chapter ? .accentColor : Color(uiColor: .label)
    }
}

private struct BibleBookPickerSheet: View {
    let books: [BibleBook]
    let currentRequest: ChapterReaderRequest
    let onSelect: (BibleBook) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(books), id: \BibleBook.bookID) { (book: BibleBook) in
                        Button {
                            onSelect(book)
                            dismiss()
                        } label: {
                            BibleBookRow(
                                title: book.bookName,
                                isSelected: book.bookName == currentRequest.book
                            )
                        }
                        .buttonStyle(.plain)

                        if book.bookID != books.last?.bookID {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
            .navigationTitle("Books")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct BibleBookRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
