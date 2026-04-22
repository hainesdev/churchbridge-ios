import SwiftUI

struct TranslationTestView: View {
    @Bindable var viewModel: TranslationTestViewModel
    @State private var selectedSegment: TranslationSegment?
    @State private var scrollToLiveRequested = 0
    @State private var userPinnedToLive = true

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.06, green: 0.08, blue: 0.11), Color(red: 0.11, green: 0.16, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 16) {
                    headerCard
                    if viewModel.isRunning || viewModel.streamStatus == .connecting || viewModel.streamStatus == .reconnecting {
                        liveFeed
                    } else {
                        idleCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle("Translation Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") { viewModel.showSettings = true }
                        .tint(.white)
                }
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsSheet(viewModel: viewModel)
                    .presentationDetents([.large])
            }
            .sheet(item: $selectedSegment) { segment in
                VerseSheet(segment: segment)
            }
            .task {
                await viewModel.onAppear()
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.settings.churchID)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Native iPhone capture with the existing Church Bridge stream contract.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                statusPill
            }

            HStack(spacing: 10) {
                metricChip(title: "Display", value: viewModel.displayConnected ? "Connected" : "Reconnecting", color: viewModel.displayConnected ? .green : .orange)
                metricChip(title: "Speech", value: viewModel.diagnostics.speechDetected ? "Detected" : "Listening", color: viewModel.diagnostics.speechDetected ? .green : .blue)
                if viewModel.diagnostics.clipping {
                    metricChip(title: "Input", value: "Clipping", color: .red)
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        if viewModel.isRunning {
                            await viewModel.stop()
                        } else {
                            await viewModel.start()
                        }
                    }
                } label: {
                    Text(viewModel.isRunning ? "Stop Test" : "Start Test")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionButtonStyle(fill: viewModel.isRunning ? .red : .green))

                Button("Reconnect Feed") {
                    Task { await viewModel.restartDisplayConnection() }
                }
                .buttonStyle(ActionButtonStyle(fill: .gray.opacity(0.3), foreground: .white))
            }

            if !viewModel.latestError.isEmpty {
                Text(viewModel.latestError)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.72))
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ready for field testing")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("Use Voice Processing first, then compare against Echo-Cancelled Input or Raw Debug in the same room.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
            diagnosticsGrid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var liveFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    diagnosticsGrid

                    if viewModel.displayFeed.snapshot.segments.isEmpty,
                       activeSpanish.isEmpty,
                       viewModel.displayFeed.snapshot.partialEnglish.isEmpty {
                        Text(waitingHint)
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }

                    ForEach(viewModel.displayFeed.snapshot.segments) { segment in
                        Button {
                            if segment.verseDetected != nil || !segment.verseSuggestions.isEmpty {
                                selectedSegment = segment
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Text(segment.english)
                                        .font(.system(.title3, design: .rounded, weight: .semibold))
                                        .foregroundStyle(segment.id == viewModel.displayFeed.snapshot.flashingID ? Color(red: 0.78, green: 0.9, blue: 1.0) : .white)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }

                                if let verse = segment.verseDetected {
                                    verseTag(title: verse.reference, tint: Color.orange)
                                }

                                if !segment.verseSuggestions.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(segment.verseSuggestions, id: \.reference) { suggestion in
                                                verseTag(title: suggestion.reference, tint: Color.blue)
                                            }
                                        }
                                    }
                                }

                                Text(segment.spanish)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(Color.white.opacity(segment.pendingCompletion ? 0.05 : 0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(segment.id)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if !viewModel.displayFeed.snapshot.partialEnglish.isEmpty {
                            Text("\(viewModel.displayFeed.snapshot.partialEnglish)\u{258C}")
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.74))
                        }
                        if !activeSpanish.isEmpty {
                            Text(activeSpanish)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.bottom, 18)

                    Color.clear
                        .frame(height: 1)
                        .id("live-bottom")
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottomTrailing) {
                if !userPinnedToLive {
                    Button {
                        userPinnedToLive = true
                        scrollToLiveRequested += 1
                    } label: {
                        Text("Live")
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
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
            .onChange(of: scrollToLiveRequested) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    userPinnedToLive = false
                }
            )
        }
    }

    private var diagnosticsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                diagnosticCard(title: "Route", value: viewModel.diagnostics.routeName, detail: routeDetail)
                diagnosticCard(title: "Sample Rate", value: "\(Int(viewModel.diagnostics.inputSampleRate)) Hz", detail: sampleRateDetail)
            }
            HStack(spacing: 12) {
                diagnosticCard(title: "Voice Processing", value: viewModel.diagnostics.voiceProcessingEnabled ? "Enabled" : "Off", detail: voiceProcessingDetail)
                diagnosticCard(title: "Echo Cancel", value: viewModel.diagnostics.echoCancelledInputEnabled ? "Enabled" : "Off", detail: viewModel.diagnostics.echoCancelledInputAvailable ? "Supported on this route" : "Unavailable")
            }
            HStack(spacing: 12) {
                diagnosticCard(title: "Capture Path", value: viewModel.diagnostics.capturePath, detail: viewModel.diagnostics.fallbackReason.isEmpty ? "Preferred native path active" : viewModel.diagnostics.fallbackReason)
                diagnosticCard(title: "Input Level", value: percent(viewModel.diagnostics.rmsLevel), detail: viewModel.diagnostics.speechDetected ? "Speech active" : "Room tone")
                diagnosticCard(title: "Chunks Emitted", value: "\(viewModel.interpreterChunksObserved)", detail: relativeTime(viewModel.interpreterLastChunkObservedAt))
            }
            HStack(spacing: 12) {
                diagnosticCard(title: "Chunks Sent", value: "\(viewModel.interpreterChunksSent)", detail: relativeTime(viewModel.interpreterLastChunkSentAt))
                diagnosticCard(title: "Send Failures", value: "\(viewModel.interpreterSendFailures)", detail: relativeTime(viewModel.interpreterLastSendFailureAt))
            }
        }
    }

    private var statusPill: some View {
        let color: Color
        let text: String
        switch viewModel.streamStatus {
        case .idle:
            color = .gray
            text = "Idle"
        case .connecting:
            color = .blue
            text = "Connecting"
        case .connected:
            color = .green
            text = "Live"
        case .reconnecting:
            color = .orange
            text = "Reconnecting"
        case .failed:
            color = .red
            text = "Error"
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

    private func diagnosticCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func verseTag(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var waitingHint: String {
        if viewModel.diagnostics.clipping {
            return "Input is clipping. Move the phone farther from the speaker or lower the source level."
        }
        if viewModel.diagnostics.rmsLevel < 0.015 {
            return "Input is low. Move the phone closer to the preacher or PA."
        }
        if let lastInterimAt = viewModel.displayFeed.snapshot.lastInterimAt,
           viewModel.displayFeed.snapshot.lastFinalAt == nil,
           Date().timeIntervalSince(lastInterimAt) > 6 {
            return "Interim speech is arriving, but STT is not settling on a final phrase yet."
        }
        if viewModel.displayFeed.snapshot.lastFinalAt != nil && viewModel.displayFeed.snapshot.lastTranslationAt == nil {
            return "Spanish finals are arriving. Waiting for committed English."
        }
        if let lastFinalAt = viewModel.displayFeed.snapshot.lastFinalAt,
           let lastTranslationAt = viewModel.displayFeed.snapshot.lastTranslationAt,
           lastTranslationAt < lastFinalAt,
           Date().timeIntervalSince(lastFinalAt) > 6 {
            return "Spanish finals are arriving, but the translation stage is lagging behind."
        }
        return "Listening for speech..."
    }

    private var activeSpanish: String {
        let lines = viewModel.displayFeed.snapshot.spanishLines.joined(separator: " ")
        if lines.isEmpty {
            return viewModel.displayFeed.snapshot.partialSpanish
        }
        if viewModel.displayFeed.snapshot.partialSpanish.isEmpty {
            return lines
        }
        return "\(lines) \(viewModel.displayFeed.snapshot.partialSpanish)"
    }

    private var routeDetail: String {
        let outputs = viewModel.diagnostics.routeOutputs.joined(separator: ", ")
        return outputs.isEmpty ? "No active output route" : outputs
    }

    private var sampleRateDetail: String {
        let format = viewModel.diagnostics.inputFormatDescription
        if format.isEmpty {
            return "Target \(Int(viewModel.diagnostics.targetSampleRate)) Hz mono"
        }
        return "\(format) to \(Int(viewModel.diagnostics.targetSampleRate)) Hz mono"
    }

    private var voiceProcessingDetail: String {
        let agc = viewModel.diagnostics.voiceProcessingAGCEnabled ? "AGC on" : "AGC off"
        return "\(viewModel.settings.captureMode.rawValue) | \(agc)"
    }

    private func percent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "No audio sent yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last \(formatter.localizedString(for: date, relativeTo: .now))"
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
                Section("Backend") {
                    TextField("Base URL", text: $viewModel.settings.baseURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    TextField("Church ID", text: $viewModel.settings.churchID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Reload Bible Versions") {
                        Task { await viewModel.loadBibleVersions() }
                    }
                }

                Section("Bible Versions") {
                    if viewModel.bibleVersions.isEmpty {
                        Text(viewModel.bibleVersionsError.isEmpty ? "No versions loaded yet." : viewModel.bibleVersionsError)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Source", selection: $viewModel.settings.sourceScriptureVersion) {
                            ForEach(viewModel.bibleVersions) { version in
                                Text("\(version.name) (\(version.slug))").tag(version.slug)
                            }
                        }

                        Picker("Display", selection: $viewModel.settings.displayScriptureVersion) {
                            ForEach(viewModel.bibleVersions) { version in
                                Text("\(version.name) (\(version.slug))").tag(version.slug)
                            }
                        }
                    }
                }

                Section("Capture Mode") {
                    Picker("Mode", selection: $viewModel.settings.captureMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text(viewModel.settings.captureMode.sessionModeDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    LabeledContent("Permission", value: viewModel.diagnostics.microphonePermissionGranted ? "Granted" : "Not granted")
                    LabeledContent("Input Route", value: viewModel.diagnostics.routeName)
                    LabeledContent("Capture Path", value: viewModel.diagnostics.capturePath)
                    LabeledContent("Input Channels", value: "\(viewModel.diagnostics.inputChannels)")
                    LabeledContent("Input Format", value: viewModel.diagnostics.inputFormatDescription)
                    LabeledContent("Voice Processing", value: viewModel.diagnostics.voiceProcessingEnabled ? "Enabled" : "Off")
                    LabeledContent("Voice Processing AGC", value: viewModel.diagnostics.voiceProcessingAGCEnabled ? "On" : "Off")
                    LabeledContent("Echo-Cancelled Input", value: viewModel.diagnostics.echoCancelledInputEnabled ? "Enabled" : "Off")
                    LabeledContent("Speech Activity", value: viewModel.diagnostics.speechDetected ? "Detected" : "Idle")
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

private struct VerseSheet: View {
    let segment: TranslationSegment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("English") {
                    Text(segment.english)
                }
                Section("Spanish") {
                    Text(segment.spanish)
                }
                if let verse = segment.verseDetected {
                    Section("Detected Verse") {
                        Text(verse.reference).font(.headline)
                        if let explanation = verse.explanation {
                            Text(explanation)
                        }
                        if let sourcePassage = verse.sourcePassage {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Source: \(sourcePassage.version.name)")
                                    .font(.subheadline.weight(.semibold))
                                Text(sourcePassage.verses.map(\.text).joined(separator: " "))
                            }
                        }
                        if let displayPassage = verse.displayPassage {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Display: \(displayPassage.version.name)")
                                    .font(.subheadline.weight(.semibold))
                                Text(displayPassage.verses.map(\.text).joined(separator: " "))
                            }
                        }
                    }
                }
                if !segment.verseSuggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(segment.verseSuggestions, id: \.reference) { suggestion in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(suggestion.reference).font(.headline)
                                Text(suggestion.explanation ?? suggestion.relevanceNote)
                                if let sourcePassage = suggestion.sourcePassage {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Source: \(sourcePassage.version.name)")
                                            .font(.subheadline.weight(.semibold))
                                        Text(sourcePassage.verses.map(\.text).joined(separator: " "))
                                    }
                                }
                                if let displayPassage = suggestion.displayPassage {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Display: \(displayPassage.version.name)")
                                            .font(.subheadline.weight(.semibold))
                                        Text(displayPassage.verses.map(\.text).joined(separator: " "))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scripture")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
