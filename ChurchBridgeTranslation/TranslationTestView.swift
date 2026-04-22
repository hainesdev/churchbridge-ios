import SwiftUI

struct TranslationTestView: View {
    @Bindable var viewModel: TranslationTestViewModel
    @State private var selectedSegment: TranslationSegment?
    @State private var scrollToLiveRequested = 0
    @State private var userPinnedToLive = true
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                background

                VStack(spacing: 14) {
                    controlBar
                    if isLive {
                        liveFeed
                    } else {
                        idleCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .navigationTitle("Interpreter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .tint(.white)

                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .tint(.white)
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
            .sheet(item: $selectedSegment) { segment in
                VerseSheet(segment: segment, baseURL: viewModel.settings.apiBaseURL, churchID: viewModel.settings.churchID)
            }
            .task {
                await viewModel.onAppear()
            }
        }
    }

    private var isLive: Bool {
        viewModel.isRunning || viewModel.streamStatus == .connecting || viewModel.streamStatus == .reconnecting
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.10), Color(red: 0.08, green: 0.14, blue: 0.11)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color(red: 0.20, green: 0.35, blue: 0.28).opacity(0.30), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.settings.churchID)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(viewModel.isRunning ? "Listening for live translation" : "Ready to start listening")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()
                statusPill
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        if viewModel.isRunning {
                            await viewModel.stop()
                        } else {
                            await viewModel.start()
                        }
                    }
                } label: {
                    Label(viewModel.isRunning ? "Stop" : "Start", systemImage: viewModel.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionButtonStyle(fill: viewModel.isRunning ? .red : .green))

                if !viewModel.displayConnected || viewModel.streamStatus == .failed {
                    Button {
                        Task { await viewModel.restartDisplayConnection() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(ActionButtonStyle(fill: .white.opacity(0.10), foreground: .white))
                }
            }

            HStack(spacing: 8) {
                metricChip(title: "Feed", value: viewModel.displayConnected ? "Connected" : "Reconnecting", color: viewModel.displayConnected ? .green : .orange)
                metricChip(title: "Audio", value: viewModel.diagnostics.speechDetected ? "Active" : "Listening", color: viewModel.diagnostics.speechDetected ? .green : .blue)
                if viewModel.diagnostics.clipping {
                    metricChip(title: "Input", value: "Clipping", color: .red)
                }
            }

            if !viewModel.latestError.isEmpty {
                Text(viewModel.latestError)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.72))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Personal interpreter, built for reading")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text("The live screen keeps the focus on translated text. Advanced diagnostics and configuration stay behind the small icons in the top-right corner.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))

            VStack(alignment: .leading, spacing: 10) {
                featureRow(icon: "captions.bubble.fill", title: "Caption-first layout", detail: "English stays prominent, with the original Spanish tucked underneath.")
                featureRow(icon: "book.closed.fill", title: "Bilingual scripture reader", detail: "Verse pills open explanation plus passages in both languages.")
                featureRow(icon: "rectangle.expand.vertical", title: "Expandable chapter reading", detail: "Read beyond the quoted range without leaving the app.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var liveFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.displayFeed.snapshot.segments.isEmpty, activeSpanish.isEmpty, viewModel.displayFeed.snapshot.partialEnglish.isEmpty {
                        waitingCard
                    }

                    ForEach(viewModel.displayFeed.snapshot.segments) { segment in
                        Button {
                            if segment.verseDetected != nil || !segment.verseSuggestions.isEmpty {
                                selectedSegment = segment
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                if segment.verseDetected != nil || !segment.verseSuggestions.isEmpty {
                                    versePillRow(for: segment)
                                }

                                Text(segment.english)
                                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                                    .foregroundStyle(segment.id == viewModel.displayFeed.snapshot.flashingID ? Color(red: 0.84, green: 0.94, blue: 1.0) : .white)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(segment.spanish)
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.58))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(cardBackground(for: segment), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(segment.id == viewModel.displayFeed.snapshot.flashingID ? 0.22 : 0.06), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
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
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("live-bottom", anchor: .bottom) }
            }
            .onChange(of: scrollToLiveRequested) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("live-bottom", anchor: .bottom) }
            }
            .simultaneousGesture(DragGesture().onChanged { _ in userPinnedToLive = false })
        }
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for speech")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text(waitingHint)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var partialCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.displayFeed.snapshot.partialEnglish.isEmpty {
                Text("\(viewModel.displayFeed.snapshot.partialEnglish)\u{258C}")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
            if !activeSpanish.isEmpty {
                Text(activeSpanish)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func versePillRow(for segment: TranslationSegment) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let verse = segment.verseDetected {
                    verseTag(title: verse.reference, subtitle: "Detected", tint: .orange)
                }
                ForEach(segment.verseSuggestions, id: \.reference) { suggestion in
                    verseTag(title: suggestion.reference, subtitle: "Suggested", tint: .blue)
                }
            }
        }
    }

    private func cardBackground(for segment: TranslationSegment) -> Color {
        segment.id == viewModel.displayFeed.snapshot.flashingID ? Color.white.opacity(0.13) : Color.white.opacity(segment.pendingCompletion ? 0.05 : 0.09)
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
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func verseTag(title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.caption, design: .rounded, weight: .bold))
            Text(subtitle.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.70, green: 0.90, blue: 0.84))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.headline, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(.subheadline, design: .rounded)).foregroundStyle(.white.opacity(0.70))
            }
        }
    }

    private var waitingHint: String {
        if viewModel.diagnostics.clipping { return "Input is clipping. Move the phone farther from the speaker or lower the source level." }
        if viewModel.diagnostics.rmsLevel < 0.015 { return "Input is low. Move the phone closer to the preacher or PA." }
        if let lastInterimAt = viewModel.displayFeed.snapshot.lastInterimAt, viewModel.displayFeed.snapshot.lastFinalAt == nil, Date().timeIntervalSince(lastInterimAt) > 6 {
            return "Interim speech is arriving, but STT is not settling on a final phrase yet."
        }
        if viewModel.displayFeed.snapshot.lastFinalAt != nil && viewModel.displayFeed.snapshot.lastTranslationAt == nil {
            return "Spanish finals are arriving. Waiting for committed English."
        }
        if let lastFinalAt = viewModel.displayFeed.snapshot.lastFinalAt, let lastTranslationAt = viewModel.displayFeed.snapshot.lastTranslationAt, lastTranslationAt < lastFinalAt, Date().timeIntervalSince(lastFinalAt) > 6 {
            return "Spanish finals are arriving, but the translation stage is lagging behind."
        }
        return "Listening for speech..."
    }

    private var activeSpanish: String {
        let lines = viewModel.displayFeed.snapshot.spanishLines.joined(separator: " ")
        if lines.isEmpty { return viewModel.displayFeed.snapshot.partialSpanish }
        if viewModel.displayFeed.snapshot.partialSpanish.isEmpty { return lines }
        return "\(lines) \(viewModel.displayFeed.snapshot.partialSpanish)"
    }
}

private struct ActionButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(foreground)
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
            }
            .navigationTitle("Advanced")
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
                    LabeledContent("Stream", value: viewModel.streamStatus.rawValue.capitalized)
                    LabeledContent("Display Feed", value: viewModel.displayConnected ? "Connected" : "Disconnected")
                    LabeledContent("Input Route", value: viewModel.diagnostics.routeName)
                    LabeledContent("Capture Path", value: viewModel.diagnostics.capturePath)
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
    enum Kind {
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

    var id: String { "\(versionSlug)-\(book)-\(chapter)" }
}

private struct VerseSheet: View {
    let segment: TranslationSegment
    let baseURL: URL?
    let churchID: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemID: String
    @State private var chapterRequest: ChapterReaderRequest?

    init(segment: TranslationSegment, baseURL: URL?, churchID: String) {
        self.segment = segment
        self.baseURL = baseURL
        self.churchID = churchID

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
                ChapterReaderSheet(request: request, baseURL: baseURL, churchID: churchID)
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.reference)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            Text(item.badgeText.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(selectedItemID == item.id ? Color.accentColor.opacity(0.18) : Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func heroCard(for item: VerseSheetItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.badgeText.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(item.reference)
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(item.explanation)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
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
                    Text(passage.reference)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Read \(passage.book) \(passage.chapter)") {
                    chapterRequest = ChapterReaderRequest(
                        versionSlug: passage.version.slug,
                        versionName: passage.version.name,
                        book: passage.book,
                        chapter: passage.chapter
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(accent)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(passage.verses, id: \.reference) { verse in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(verse.verse)")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(accent)
                            .frame(width: 28, alignment: .leading)
                        Text(verse.text)
                            .font(.system(.body, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ChapterReaderSheet: View {
    let request: ChapterReaderRequest
    let baseURL: URL?
    let churchID: String

    @Environment(\.dismiss) private var dismiss
    @State private var chapter: ScriptureChapter?
    @State private var errorMessage = ""
    @State private var isLoading = true

    private let service = BibleVersionService()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading \(request.book) \(request.chapter)…")
                } else if let chapter {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(chapter.reference)
                                    .font(.system(.title2, design: .rounded, weight: .bold))
                                Text(chapter.version.name)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(chapter.verses, id: \.reference) { verse in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(verse.verse)")
                                        .font(.system(.headline, design: .rounded, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 30, alignment: .leading)
                                    Text(verse.text)
                                        .font(.system(.body, design: .rounded))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView(
                        "Chapter unavailable",
                        systemImage: "book.closed",
                        description: Text(errorMessage.isEmpty ? "We couldn't load this chapter right now." : errorMessage)
                    )
                }
            }
            .task {
                await loadChapter()
            }
            .navigationTitle("Reader")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
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
            chapter = try await service.fetchChapter(
                baseURL: baseURL,
                churchID: churchID,
                versionSlug: request.versionSlug,
                book: request.book,
                chapter: request.chapter
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
