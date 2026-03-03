import Foundation
import SwiftUI
import Combine

class RecordingViewModel: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var isPaused: Bool = false
    @Published var currentDuration: TimeInterval = 0
    @Published var transcribedText: String = ""
    @Published var errorMessage: String?
    @Published var permissionsGranted: Bool = false
    @Published var toastMessage: ToastMessage?
    @Published var isExporting: Bool = false
    @Published var isGeneratingNotes: Bool = false
    @Published var isImprovingTranscript: Bool = false
    @Published var userNotes: String = ""
    @Published var userNotesTitle: String = ""

    // Intent Markers and Catch-Up
    @Published var intentMarkers: [IntentMarker] = []
    @Published var isCatchUpLoading: Bool = false
    @Published var lastCatchUpSummary: CatchUpSummary?

    let audioService = AudioRecordingService()
    let transcriptionService = TranscriptionService()
    private let geminiService = GeminiService.shared

    private var currentAudioURL: URL?
    private var cancellables = Set<AnyCancellable>()

    @AppStorage("autoGenerateClassNotes") private var autoGenerateClassNotes = false
    @AppStorage("realtimeTranscription") private var realtimeTranscription = true
    @AppStorage("generateRecallPrompts") private var generateRecallPrompts = true

    init() {
        setupBindings()
    }

    private func setupBindings() {
        // Bind audio service duration to our published property
        audioService.$currentDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.currentDuration = duration
            }
            .store(in: &cancellables)

        // Bind transcription service text to our published property
        transcriptionService.$transcribedText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.transcribedText = text
            }
            .store(in: &cancellables)

        // Bind transcription errors
        transcriptionService.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.errorMessage = error
                }
            }
            .store(in: &cancellables)
    }

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        audioService.requestPermission { [weak self] audioGranted in
            guard audioGranted else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Microphone permission denied"
                }
                completion(false)
                return
            }

            self?.transcriptionService.requestPermission { speechGranted in
                DispatchQueue.main.async {
                    if speechGranted {
                        self?.permissionsGranted = true
                        completion(true)
                    } else {
                        self?.errorMessage = "Speech recognition permission denied"
                        completion(false)
                    }
                }
            }
        }
    }

    func startRecording() {
        // Clear any previous error/state
        DispatchQueue.main.async {
            self.errorMessage = nil
            self.transcribedText = ""
        }

        // Start transcription FIRST so the buffer handler is set up
        // before SharedAudioManager starts sending audio buffers
        if realtimeTranscription {
            transcriptionService.startTranscribing()
        }

        guard let audioURL = audioService.startRecording() else {
            DispatchQueue.main.async {
                self.errorMessage = self.audioService.lastError ?? "Failed to start recording"
            }
            if realtimeTranscription {
                transcriptionService.stopTranscribing()
            }
            return
        }

        currentAudioURL = audioURL

        DispatchQueue.main.async {
            self.isRecording = true
            self.isPaused = false
        }
    }

    func pauseRecording() {
        audioService.pauseRecording()
        if realtimeTranscription {
            transcriptionService.pauseTranscribing()
        }
        DispatchQueue.main.async {
            self.isPaused = true
        }
    }

    func resumeRecording() {
        audioService.resumeRecording()
        if realtimeTranscription {
            transcriptionService.resumeTranscribing()
        }
        DispatchQueue.main.async {
            self.isPaused = false
        }
    }

    func stopRecording(classModel: SDClass, classViewModel: ClassViewModel) {
        guard let result = audioService.stopRecording() else {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to stop recording"
            }
            return
        }

        if realtimeTranscription {
            transcriptionService.stopTranscribing()
        }

        let recordingDate = Date()
        let audioURL = result.url
        let wasRealtimeTranscription = realtimeTranscription

        // Combine title with notes if title exists
        let finalUserNotes: String
        if !userNotesTitle.isEmpty {
            finalUserNotes = "# \(userNotesTitle)\n\n\(userNotes)"
        } else {
            finalUserNotes = userNotes
        }

        // Capture intent markers and catch-up summaries
        let finalIntentMarkers = intentMarkers
        let finalCatchUpSummaries = lastCatchUpSummary.map { [$0] } ?? []

        // If transcription was disabled during recording, transcribe the file now
        if !wasRealtimeTranscription {
            Task { @MainActor in
                do {
                    // Show transcription progress
                    self.toastMessage = ToastMessage(
                        message: "Transcribing audio file...",
                        icon: "waveform",
                        type: .info
                    )

                    let transcript = try await transcriptionService.transcribeAudioFile(url: audioURL)

                    // Update toast to show transcription completed
                    if !transcript.isEmpty {
                        self.toastMessage = ToastMessage(
                            message: "Transcription complete",
                            icon: "checkmark.circle.fill",
                            type: .success
                        )
                    }

                    self.processRecording(
                        classId: classModel.id,
                        date: recordingDate,
                        duration: result.duration,
                        audioURL: audioURL,
                        transcript: transcript,
                        userNotes: finalUserNotes,
                        intentMarkers: finalIntentMarkers,
                        catchUpSummaries: finalCatchUpSummaries,
                        classModel: classModel,
                        classViewModel: classViewModel,
                        skipGeminiUpgrade: true // battery-save already transcribed via on-device pass
                    )
                } catch {
                    self.errorMessage = "Failed to transcribe recording: \(error.localizedDescription)"
                    self.toastMessage = ToastMessage(
                        message: "Transcription failed",
                        icon: "exclamationmark.triangle.fill",
                        type: .error
                    )

                    // Still process recording without transcript
                    self.processRecording(
                        classId: classModel.id,
                        date: recordingDate,
                        duration: result.duration,
                        audioURL: audioURL,
                        transcript: "",
                        userNotes: finalUserNotes,
                        intentMarkers: finalIntentMarkers,
                        catchUpSummaries: finalCatchUpSummaries,
                        classModel: classModel,
                        classViewModel: classViewModel,
                        skipGeminiUpgrade: true
                    )
                }

                self.reset()
            }
        } else {
            // Use live transcript directly
            let finalTranscript = transcribedText

            processRecording(
                classId: classModel.id,
                date: recordingDate,
                duration: result.duration,
                audioURL: audioURL,
                transcript: finalTranscript,
                userNotes: finalUserNotes,
                intentMarkers: finalIntentMarkers,
                catchUpSummaries: finalCatchUpSummaries,
                classModel: classModel,
                classViewModel: classViewModel
            )

            reset()
        }
    }

    private func processRecording(
        classId: UUID,
        date: Date,
        duration: TimeInterval,
        audioURL: URL,
        transcript: String,
        userNotes: String,
        intentMarkers: [IntentMarker],
        catchUpSummaries: [CatchUpSummary],
        classModel: SDClass,
        classViewModel: ClassViewModel,
        skipGeminiUpgrade: Bool = false
    ) {
        let audioFileName = audioURL.lastPathComponent
        let recording = SDRecording(
            classId: classId,
            date: date,
            duration: duration,
            audioFileName: audioFileName,
            transcriptText: transcript,
            userNotes: userNotes,
            classNotes: nil,
            pdfExported: false,
            name: SDRecording.generateDefaultName(className: classModel.name, date: date),
            intentMarkers: intentMarkers,
            catchUpSummaries: catchUpSummaries
        )

        Task { @MainActor in
            classViewModel.addRecording(recording)

            // Step 1: Run the on-device offline pass first so AI notes are generated
            // from the best available transcript, not the raw live result.
            // Battery-save mode (skipGeminiUpgrade=true) already did this pass.
            if !skipGeminiUpgrade {
                await self.runOfflineTranscriptUpgrade(for: recording, audioURL: audioURL)
            }

            // Step 2: Generate AI notes from the now-improved transcript
            if self.autoGenerateClassNotes && !recording.transcriptText.isEmpty {
                await self.generateEnhancedContent(for: recording, classModel: classModel, classViewModel: classViewModel)
            } else {
                self.exportPDF(for: recording, classModel: classModel, classViewModel: classViewModel)
            }
        }
    }

    // MARK: - Post-Processing Pipeline

    /// Runs the on-device SpeechAnalyzer offline pass and awaits completion.
    /// Called before AI note generation so notes use the best transcript available.
    @MainActor
    private func runOfflineTranscriptUpgrade(for recording: SDRecording, audioURL: URL) async {
        isImprovingTranscript = true
        toastMessage = ToastMessage(message: "Refining transcript on-device...", icon: "waveform.badge.magnifyingglass", type: .info)

        do {
            let offlineTranscript = try await transcriptionService.transcribeAudioFile(url: audioURL)
            if !offlineTranscript.isEmpty {
                recording.transcriptText = offlineTranscript
                toastMessage = ToastMessage(message: "Transcript refined — generating notes...", icon: "checkmark.circle", type: .success)
            }
        } catch {
            print("Offline transcript upgrade failed (non-fatal): \(error.localizedDescription)")
        }

        isImprovingTranscript = false
    }

    // MARK: - Manual Gemini Audio Transcription

    /// Manually triggered by the user from the recording detail view.
    /// Uploads the audio file to Gemini 2.5 Flash for the highest-quality transcript
    /// with punctuation, speaker labels, and domain vocabulary correction.
    func improveTranscriptWithGemini(for recording: SDRecording) async {
        guard let audioURL = recording.audioFileURL() else {
            await MainActor.run { self.errorMessage = "Audio file not found for this recording." }
            return
        }
        guard let apiKey = KeychainHelper.shared.getGeminiAPIKey(), !apiKey.isEmpty else {
            await MainActor.run { self.errorMessage = "Add a Gemini API key in Settings to use this feature." }
            return
        }
        _ = apiKey

        await MainActor.run {
            self.isImprovingTranscript = true
            self.toastMessage = ToastMessage(message: "Uploading audio to Gemini...", icon: "sparkles", type: .info)
        }

        do {
            let improvedTranscript = try await geminiService.transcribeAudioFile(at: audioURL)
            await MainActor.run {
                defer { self.isImprovingTranscript = false }
                guard !improvedTranscript.isEmpty else { return }
                recording.transcriptText = improvedTranscript
                self.toastMessage = ToastMessage(message: "Transcript upgraded with AI", icon: "sparkles", type: .success)
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Gemini transcription failed: \(error.localizedDescription)"
                self.isImprovingTranscript = false
            }
        }
    }

    // MARK: - Enhanced Content Generation

    /// Regenerates all AI content (class notes, enhanced summary, recall prompts) for an existing recording.
    /// Call this from the detail view when the user wants to retry after a failure.
    func regenerateAIContent(for recording: SDRecording) async {
        guard !recording.transcriptText.isEmpty else { return }
        await generateEnhancedContent(for: recording, classModel: nil, classViewModel: nil)
    }

    private func generateEnhancedContent(for recording: SDRecording, classModel: SDClass?, classViewModel: ClassViewModel?) async {
        await MainActor.run {
            self.isGeneratingNotes = true
        }

        let transcriptText = recording.transcriptText
        let userNotesText = recording.userNotes
        let markers = recording.intentMarkers

        let noteStyleRaw = UserDefaults.standard.string(forKey: "noteStyle") ?? NoteStyle.detailed.rawValue
        let summaryLengthRaw = UserDefaults.standard.string(forKey: "summaryLength") ?? SummaryLength.comprehensive.rawValue
        let noteStyle = NoteStyle(rawValue: noteStyleRaw) ?? .detailed
        let summaryLength = SummaryLength(rawValue: summaryLengthRaw) ?? .comprehensive

        do {
            // Run AI generation tasks in parallel for ~2-3x speedup
            let shouldGenerateRecall = generateRecallPrompts

            async let classNotesTask = geminiService.generateClassNotes(
                from: transcriptText,
                userNotes: userNotesText,
                noteStyle: noteStyle,
                summaryLength: summaryLength
            )

            async let enhancedSummaryTask = geminiService.generateEnhancedSummaries(
                from: transcriptText,
                markers: markers,
                userNotes: userNotesText
            )

            async let recallPromptsTask: RecallPrompts? = shouldGenerateRecall
                ? try await geminiService.generateRecallPrompts(from: transcriptText, markers: markers)
                : nil

            let classNotes = try await classNotesTask
            let enhancedSummary = try await enhancedSummaryTask
            let recallPrompts = try await recallPromptsTask

            await MainActor.run {
                recording.classNotes = classNotes
                recording.enhancedSummary = enhancedSummary
                recording.recallPrompts = recallPrompts

                classViewModel?.updateRecording(recording)
                self.isGeneratingNotes = false

                if let classModel, let classViewModel {
                    self.exportPDF(for: recording, classModel: classModel, classViewModel: classViewModel)
                }
            }

        } catch {
            await MainActor.run {
                self.isGeneratingNotes = false
                self.errorMessage = error.localizedDescription

                if let classModel, let classViewModel {
                    self.exportPDF(for: recording, classModel: classModel, classViewModel: classViewModel)
                }
            }
        }
    }

    func cancelRecording() {
        if let result = audioService.stopRecording() {
            try? FileManager.default.removeItem(at: result.url)
        }
        transcriptionService.stopTranscribing()

        // Clear any pending toast message when canceling
        DispatchQueue.main.async {
            self.toastMessage = nil
        }

        reset()
    }

    // MARK: - Intent Markers

    /// Adds an intent marker at the current timestamp
    func addIntentMarker(type: IntentMarkerType) {
        let snapshot = getRecentTranscriptSnapshot(wordCount: 30)
        let marker = IntentMarker(
            type: type,
            timestamp: currentDuration,
            transcriptSnapshot: snapshot
        )

        DispatchQueue.main.async {
            self.intentMarkers.append(marker)
        }
    }

    /// Gets the last N words from the transcript
    private func getRecentTranscriptSnapshot(wordCount: Int) -> String? {
        let words = transcribedText.split(separator: " ")
        guard !words.isEmpty else { return nil }

        let recentWords = words.suffix(wordCount)
        return recentWords.joined(separator: " ")
    }

    // MARK: - Catch-Up Summary

    /// Requests a catch-up summary for what was missed recently
    func requestCatchUpSummary() async {
        // Need at least some transcript to summarize
        guard !transcribedText.isEmpty else { return }

        await MainActor.run {
            self.isCatchUpLoading = true
        }

        // Estimate transcript coverage - assume ~150 words per minute
        // Get last ~2.5 minutes worth (roughly 375 words)
        let words = transcribedText.split(separator: " ")
        let recentWordCount = min(375, words.count)
        let contextWordCount = min(200, max(0, words.count - recentWordCount))

        let recentWords = words.suffix(recentWordCount)
        let contextWords = words.dropLast(recentWordCount).suffix(contextWordCount)

        let recentTranscript = recentWords.joined(separator: " ")
        let previousContext = contextWords.joined(separator: " ")

        // Calculate time coverage
        let requestedAt = currentDuration
        let estimatedCoverageTime = Double(recentWordCount) / 150.0 * 60.0 // seconds
        let coveringFrom = max(0, requestedAt - estimatedCoverageTime)

        do {
            let summary = try await geminiService.generateCatchUpSummary(
                recentTranscript: recentTranscript,
                previousContext: previousContext
            )

            let catchUpSummary = CatchUpSummary(
                requestedAt: requestedAt,
                coveringFrom: coveringFrom,
                summary: summary
            )

            await MainActor.run {
                self.lastCatchUpSummary = catchUpSummary
                self.isCatchUpLoading = false
            }
        } catch {
            await MainActor.run {
                self.isCatchUpLoading = false
                self.errorMessage = "Failed to generate catch-up summary: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - PDF Export

    private func exportPDF(for recording: SDRecording, classModel: SDClass, classViewModel: ClassViewModel) {
        guard classModel.hasLocalFolder else {
            return
        }

        // Capture values for background thread
        let className = classModel.name
        let recordingDate = recording.date
        let recordingDuration = recording.duration
        let transcriptText = recording.transcriptText
        let userNotes = recording.userNotes
        let classNotes = recording.classNotes

        DispatchQueue.main.async {
            self.isExporting = true
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            guard let pdfData = PDFExportService.generatePDF(
                className: className,
                date: recordingDate,
                duration: recordingDuration,
                transcriptText: transcriptText,
                userNotes: userNotes,
                classNotes: classNotes
            ) else {
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = "Failed to generate PDF"
                }
                return
            }

            let fileName = self.generateFileName(className: className, date: recordingDate)

            var localSuccess = false
            if let folderURL = classModel.resolveFolder() {
                localSuccess = PDFExportService.savePDF(data: pdfData, to: folderURL, fileName: fileName)
            }

            await MainActor.run {
                self.isExporting = false

                recording.pdfExported = localSuccess
                classViewModel.updateRecording(recording)

                if localSuccess {
                    self.toastMessage = ToastMessage(
                        message: "PDF saved to \(classModel.resolveFolder()?.lastPathComponent ?? "folder")",
                        icon: "checkmark.circle.fill",
                        type: .success
                    )
                } else {
                    self.toastMessage = ToastMessage(
                        message: "Failed to save PDF locally",
                        icon: "exclamationmark.triangle.fill",
                        type: .error
                    )
                }
            }
        }
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let fileNameTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h-mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private func generateFileName(className: String, date: Date) -> String {
        let datePart = Self.fileNameDateFormatter.string(from: date)
        let timePart = Self.fileNameTimeFormatter.string(from: date)
        return "\(className)_\(datePart)_\(timePart)"
    }

    private func reset() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.isPaused = false
            self.currentDuration = 0
            self.transcribedText = ""
            self.userNotes = ""
            self.userNotesTitle = ""
            self.currentAudioURL = nil
            self.errorMessage = nil
            self.intentMarkers = []
            self.lastCatchUpSummary = nil
            self.isCatchUpLoading = false
        }
    }

    var formattedDuration: String {
        let hours = Int(currentDuration) / 3600
        let minutes = (Int(currentDuration) % 3600) / 60
        let seconds = Int(currentDuration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
