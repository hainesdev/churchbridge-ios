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
    @State private var liveDockScrollToken = 0
    @State private var liveDockScrollTask: Task<Void, Never>?

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
                VStack(spacing: 0) {
                    if isLive || viewModel.displayFeed.snapshot.liveDock.isVisible {
                        liveDock
                    }
                    mainControlBar
                }
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
                VerseSheet(segment: segment, baseURL: viewModel.settings.apiBaseURL, churchID: viewModel.settings.churchID, settings: viewModel.settings, bibleData: viewModel.bibleData)
            }
            .sheet(item: $bibleReaderRequest) { request in
                ChapterReaderSheet(request: request, baseURL: viewModel.settings.apiBaseURL, churchID: viewModel.settings.churchID, settings: viewModel.settings, bibleData: viewModel.bibleData)
            }
            .sheet(isPresented: $showBibleContents) {
                if let defaultBibleRequest {
                    ChapterReaderSheet(
                        request: defaultBibleRequest,
                        baseURL: viewModel.settings.apiBaseURL,
                        churchID: viewModel.settings.churchID,
                        settings: viewModel.settings,
                        bibleData: viewModel.bibleData,
                        showContentsOnAppear: true
                    )
                }
            }
            .task {
                await viewModel.onAppear()
            }
            .onChange(of: viewModel.displayFeed.snapshot.liveDock.english) { _, english in
                guard !english.isEmpty else { return }
                scheduleLiveDockScroll()
            }
            .onChange(of: viewModel.displayFeed.snapshot.liveDock.isVisible) { _, isVisible in
                guard isVisible else {
                    liveDockScrollTask?.cancel()
                    return
                }
                scheduleLiveDockScroll()
            }
            .onChange(of: isLive) { _, live in
                if live {
                    registerNavBarAutoHide()
                } else {
                    navBarHideTask?.cancel()
                    liveDockScrollTask?.cancel()
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
            highlightVerse: viewModel.settings.lastBibleVerse,
            highlightVerseEnd: nil
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
            highlightVerse: nil,
            highlightVerseEnd: nil
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

                    if viewModel.displayFeed.snapshot.segments.isEmpty, !viewModel.displayFeed.snapshot.liveDock.isVisible {
                        waitingCard
                    }

                    ForEach(viewModel.displayFeed.snapshot.segments) { segment in
                        translationSegmentView(segment: segment)
                            .id(segment.id)
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

        VStack(alignment: .leading, spacing: 10) {
            Text(segment.english)
                .font(translationTitleFont)
                .foregroundStyle(englishColor)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasVerses {
                versePillRow(for: segment)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.liveCardBackground(flashed: isFlashed, pending: segment.pendingCompletion), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(borderOpacity), lineWidth: 1))
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

    private var liveDock: some View {
        liveDockTextArea
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var liveDockTextArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if viewModel.displayFeed.snapshot.liveDock.isVisible {
                        Text("\(viewModel.displayFeed.snapshot.liveDock.english)\u{258C}")
                            .font(translationTitleFont)
                            .foregroundStyle(.white.opacity(0.86))
                    } else {
                        Text("Listening for the next line…")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.white.opacity(AppTheme.textTertiary))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .id("live-dock-text")
            }
            .frame(maxHeight: liveDockMaxHeight)
            .onChange(of: liveDockScrollToken) { _, _ in
                guard viewModel.displayFeed.snapshot.liveDock.isVisible else { return }
                if reduceMotion {
                    proxy.scrollTo("live-dock-text", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("live-dock-text", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var liveDockMaxHeight: CGFloat {
        let lineHeight = UIFont.systemFont(ofSize: liveDockFontSize, weight: .semibold).lineHeight
        return (lineHeight * 3) + 6
    }

    private var liveDockFontSize: CGFloat {
        let base = CGFloat(viewModel.settings.translationTextSize)
        let scale = UIFont.preferredFont(forTextStyle: .body).pointSize / 17.0
        return min(40, max(20, base * min(scale, 1.35)))
    }

    private func scheduleLiveDockScroll() {
        liveDockScrollTask?.cancel()
        liveDockScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            liveDockScrollToken += 1
        }
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
                    verseTag(title: verse.reference, tint: .orange) {
                        selectedSegment = segment
                    }
                }
                ForEach(segment.verseSuggestions, id: \.reference) { suggestion in
                    verseTag(title: suggestion.reference, tint: .blue) {
                        selectedSegment = segment
                    }
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

    private func verseTag(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tint.opacity(0.14), in: Capsule())
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
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
                    Text("Live capture uses the Robust Voice Filter path with Apple voice processing plus local speech cleanup. Advanced diagnostics stay in the waveform panel.")
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
    let highlightVerseEnd: Int?

    var id: String { "\(versionSlug)-\(book)-\(chapter)-\(highlightVerse ?? 0)-\(highlightVerseEnd ?? 0)" }
}


private struct VerseSheet: View {
    let segment: TranslationSegment
    let baseURL: URL?
    let churchID: String
    let settings: SettingsStore
    let bibleData: BibleDataManager

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemID: String
    @State private var chapterRequest: ChapterReaderRequest?

    private let cardInk = Color.black.opacity(0.88)
    private let cardSecondaryInk = Color.black.opacity(0.62)
    private let chipInk = Color(red: 0.13, green: 0.13, blue: 0.15)

    init(segment: TranslationSegment, baseURL: URL?, churchID: String, settings: SettingsStore, bibleData: BibleDataManager) {
        self.segment = segment
        self.baseURL = baseURL
        self.churchID = churchID
        self.settings = settings
        self.bibleData = bibleData

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

                        if let displayPassage = selectedItem.displayPassage {
                            passageCard(
                                title: displayPassage.version.name,
                                languageLabel: "English",
                                passage: displayPassage,
                                accent: .blue
                            )
                        }

                        if let sourcePassage = selectedItem.sourcePassage {
                            passageCard(
                                title: sourcePassage.version.name,
                                languageLabel: "Spanish",
                                passage: sourcePassage,
                                accent: .orange
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
                ChapterReaderSheet(request: request, baseURL: baseURL, churchID: churchID, settings: settings, bibleData: bibleData)
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
                        highlightVerse: passage.verseStart,
                        highlightVerseEnd: passage.verseEnd
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
    let bibleData: BibleDataManager
    let showContentsOnAppear: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceReaderMotion

    @State private var target: ChapterReaderRequest
    @State private var chapter: ScriptureChapter?
    @State private var books: [BibleBook] = []
    @State private var isLoading = true
    @State private var errorMessage = ""
    @State private var showTableOfContents = false
    @State private var scrollRequest = 0
    @State private var didAutoOpenContents = false

    private let service = BibleVersionService()
    private let cardInk = Color.black.opacity(0.88)
    private let cardSecondaryInk = Color.black.opacity(0.62)
    private let cardTertiaryInk = Color.black.opacity(0.48)
    private let horizontalSwipeThreshold: CGFloat = 72

    private var verseCardPadding: CGFloat { dynamicTypeSize >= .accessibility1 ? 20 : 18 }
    private var verseRowVerticalPadding: CGFloat { dynamicTypeSize >= .accessibility1 ? 12 : 10 }

    init(request: ChapterReaderRequest, baseURL: URL?, churchID: String, settings: SettingsStore, bibleData: BibleDataManager, showContentsOnAppear: Bool = false) {
        self.request = request
        self.baseURL = baseURL
        self.churchID = churchID
        self.settings = settings
        self.bibleData = bibleData
        self.showContentsOnAppear = showContentsOnAppear
        _target = State(initialValue: request)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if chapter != nil {
                    readerScrollView
                } else if !bibleData.isReady && isLocalVersion {
                    bibleUnavailableView
                } else {
                    bookUnavailableView
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .task(id: loadTaskID) {
                await loadContent()
            }
            .navigationTitle("\(target.book) \(target.chapter)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showTableOfContents = true } label: {
                        Label("Contents", systemImage: "list.bullet")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showTableOfContents) {
                BibleContentsSheet(books: books, currentRequest: currentReaderRequest) { req in
                    handleContentsSelection(req)
                }
            }
        }
    }

    // MARK: - Subviews

    private var readerScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("chapter-top")

                    if let chapter {
                        chapterSection(for: chapter)
                            .padding(16)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(chapterNavigationGesture)
            .onAppear { scrollToRequestedVerse(using: proxy) }
            .onChange(of: scrollRequest) { _, _ in
                scrollToRequestedVerse(using: proxy)
            }
        }
    }

    private func chapterSection(for chapter: ScriptureChapter) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chapter.verses, id: \.verse) { verse in
                    verseRow(chapter: chapter, verse: verse)
                }
            }

            if let nextChapter = adjacentChapterRequest(step: 1) {
                nextChapterCue(for: nextChapter)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(verseCardPadding)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .id(chapter.reference)
    }

    @ViewBuilder
    private func verseRow(chapter: ScriptureChapter, verse: ScripturePassageVerse) -> some View {
        let highlightStart = target.highlightVerse
        let highlightEnd = target.highlightVerseEnd ?? highlightStart
        let isHighlighted = highlightStart.map { start in
            let end = highlightEnd ?? start
            return (start...end).contains(verse.verse)
        } ?? false
            && chapter.chapter == target.chapter
            && chapter.book == target.book
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
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.accentColor.opacity(0.42) : .clear,
                    lineWidth: isHighlighted ? 1.5 : 0
                )
        }
        .id(verseRowScrollID(book: chapter.book, chapter: chapter.chapter, verse: verse.verse))
    }

    private func nextChapterCue(for request: ChapterReaderRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.bottom, 10)

            Text("Next: \(request.book) \(request.chapter)")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundColor(cardInk)

            HStack(spacing: 6) {
                Text("Swipe left to continue")
                    .font(.system(.subheadline, design: .rounded))
                Image(systemName: "arrow.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(cardTertiaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next chapter, \(request.book) \(request.chapter). Swipe left to continue.")
    }

    private var bibleUnavailableView: some View {
        Group {
            switch bibleData.downloadState {
            case .pending, .downloading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Downloading Bible data…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .failed(let msg):
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Bible unavailable",
                        systemImage: "icloud.slash",
                        description: Text(msg)
                    )
                    Button("Retry") {
                        Task { await bibleData.retry(baseURL: baseURL) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bookUnavailableView: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Book unavailable",
                systemImage: "book.closed",
                description: Text(errorMessage.isEmpty ? "We couldn't load this book right now." : errorMessage)
            )
            if !errorMessage.isEmpty {
                Button("Try again") {
                    Task { await loadContent() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Computed

    private var isLocalVersion: Bool { LocalBibleLibrary.isAvailable(target.versionSlug) }

    private var currentReaderRequest: ChapterReaderRequest {
        ChapterReaderRequest(
            versionSlug: target.versionSlug,
            versionName: target.versionName,
            book: target.book,
            chapter: target.chapter,
            highlightVerse: nil,
            highlightVerseEnd: nil
        )
    }

    private var loadTaskID: String {
        "\(bibleData.isReady)-\(target.id)"
    }

    private var chapterNavigationGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                handleHorizontalSwipe(value.translation)
            }
    }

    // MARK: - Loading

    private func loadContent() async {
        guard bibleData.isReady || !isLocalVersion else { isLoading = false; return }
        isLoading = true
        errorMessage = ""
        chapter = nil
        if isLocalVersion {
            await loadLocalBible()
        } else {
            await loadRemoteChapter()
        }
        isLoading = false
        if chapter != nil {
            scrollRequest += 1
            persistLocation()
        }
        if showContentsOnAppear && !didAutoOpenContents && !books.isEmpty {
            didAutoOpenContents = true
            showTableOfContents = true
        }
    }

    private func loadLocalBible() async {
        let lib = LocalBibleLibrary.shared
        async let booksTask = lib.books(versionSlug: target.versionSlug)
        async let chapterTask = lib.chapter(versionSlug: target.versionSlug, book: target.book, chapterNumber: target.chapter)
        let (fetchedBooks, fetchedChapter) = await (booksTask, chapterTask)
        books = fetchedBooks
        chapter = fetchedChapter
        if chapter == nil { errorMessage = "Bible not available." }
    }

    private func loadRemoteChapter() async {
        guard let baseURL else { errorMessage = "Missing backend base URL."; return }
        do {
            async let booksTask = service.fetchBooks(baseURL: baseURL, churchID: churchID, versionSlug: target.versionSlug)
            async let chapterTask = service.fetchChapter(baseURL: baseURL, churchID: churchID, versionSlug: target.versionSlug, book: target.book, chapter: target.chapter)
            let (fetchedBooks, fetchedChapter) = try await (booksTask, chapterTask)
            books = fetchedBooks
            chapter = fetchedChapter
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation

    private func handleContentsSelection(_ req: ChapterReaderRequest) {
        target = req
        showTableOfContents = false
    }

    private func navigateToAdjacentChapter(step: Int) {
        guard let nextTarget = adjacentChapterRequest(step: step) else { return }
        target = nextTarget
    }

    private func adjacentChapterRequest(step: Int) -> ChapterReaderRequest? {
        guard let bookIndex = books.firstIndex(where: { $0.bookName == target.book }) else { return nil }
        let currentBook = books[bookIndex]
        let proposedChapter = target.chapter + step

        if proposedChapter >= 1, proposedChapter <= currentBook.chapterCount {
            return ChapterReaderRequest(
                versionSlug: target.versionSlug,
                versionName: target.versionName,
                book: currentBook.bookName,
                chapter: proposedChapter,
                highlightVerse: nil,
                highlightVerseEnd: nil
            )
        }

        let adjacentBookIndex = bookIndex + step
        guard books.indices.contains(adjacentBookIndex) else { return nil }
        let adjacentBook = books[adjacentBookIndex]

        return ChapterReaderRequest(
            versionSlug: target.versionSlug,
            versionName: target.versionName,
            book: adjacentBook.bookName,
            chapter: step > 0 ? 1 : adjacentBook.chapterCount,
            highlightVerse: nil,
            highlightVerseEnd: nil
        )
    }

    private func handleHorizontalSwipe(_ translation: CGSize) {
        let horizontal = translation.width
        let vertical = translation.height
        guard abs(horizontal) >= horizontalSwipeThreshold, abs(horizontal) > abs(vertical) else { return }
        navigateToAdjacentChapter(step: horizontal < 0 ? 1 : -1)
    }

    // MARK: - Scroll

    private func scrollToRequestedVerse(using proxy: ScrollViewProxy) {
        guard let verse = target.highlightVerse else {
            if let chapter {
                proxy.scrollTo(chapter.reference, anchor: .top)
            }
            return
        }
        let verseID = verseRowScrollID(book: target.book, chapter: target.chapter, verse: verse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let scrollAction = { proxy.scrollTo(verseID, anchor: .center) }
            if reduceReaderMotion {
                scrollAction()
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollAction()
                }
            }
        }
    }

    // MARK: - Helpers

    private func verseRowScrollID(book: String, chapter: Int, verse: Int) -> String {
        "\(book) \(chapter):\(verse)"
    }

    private func persistLocation() {
        settings.saveBibleLocation(
            versionSlug: target.versionSlug,
            versionName: target.versionName,
            book: target.book,
            chapter: target.chapter,
            verse: target.highlightVerse
        )
    }

}

private struct BibleContentsSheet: View {
    let books: [BibleBook]
    let currentRequest: ChapterReaderRequest
    let onSelect: (ChapterReaderRequest) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(books, id: \.bookID) { book in
                    NavigationLink {
                        BibleChapterPickerView(book: book, currentRequest: currentRequest) { chapter in
                            onSelect(
                                ChapterReaderRequest(
                                    versionSlug: currentRequest.versionSlug,
                                    versionName: currentRequest.versionName,
                                    book: book.bookName,
                                    chapter: chapter,
                                    highlightVerse: nil,
                                    highlightVerseEnd: nil
                                )
                            )
                            dismiss()
                        }
                    } label: {
                        BibleBookRow(title: book.bookName, isSelected: book.bookName == currentRequest.book)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Contents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct BibleChapterPickerView: View {
    let book: BibleBook
    let currentRequest: ChapterReaderRequest
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 12)], spacing: 12) {
                    ForEach(1...book.chapterCount, id: \.self) { chapter in
                        Button {
                            onSelect(chapter)
                        } label: {
                            Text("\(chapter)")
                                .font(.system(.body, design: .rounded, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(chapterFill(for: chapter), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .foregroundStyle(chapterForeground(for: chapter))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(book.bookName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chapterFill(for chapter: Int) -> Color {
        isCurrentChapter(chapter) ? Color.accentColor : Color(uiColor: .secondarySystemBackground)
    }

    private func chapterForeground(for chapter: Int) -> Color {
        isCurrentChapter(chapter) ? .white : Color(uiColor: .label)
    }

    private func isCurrentChapter(_ chapter: Int) -> Bool {
        currentRequest.book == book.bookName && currentRequest.chapter == chapter
    }
}

private struct BibleBookRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(Color(uiColor: .label))

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
