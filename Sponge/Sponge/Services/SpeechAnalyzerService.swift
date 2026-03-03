//
//  SpeechAnalyzerService.swift
//  Sponge
//
//  Voice Memos-level transcription using macOS 26+ SpeechAnalyzer API
//

import Foundation
import Speech
import AVFoundation

class SpeechAnalyzerService: ObservableObject {
    @Published var transcribedText: String = ""
    @Published var isTranscribing: Bool = false
    @Published var error: String?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var isStoppingIntentionally = false

    // Audio format conversion
    private var audioConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    // Accumulates text across transcriber restarts to prevent words from disappearing
    private var baseTranscript: String = ""
    private var lastResultLength: Int = 0

    init() {
        // Format will be negotiated dynamically via SpeechAnalyzer.bestAvailableAudioFormat in startTranscribing()
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    /// Called by TranscriptionService to feed audio buffers from SharedAudioManager
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat = analyzerFormat else { return }

        // Create converter lazily based on the incoming buffer format
        if audioConverter == nil {
            let inputFormat = buffer.format
            audioConverter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            if audioConverter == nil {
                print("SpeechAnalyzer: Failed to create audio converter from \(inputFormat) to \(analyzerFormat)")
                return
            }
        }

        guard let converter = audioConverter else { return }

        // Convert to analyzer format (16-bit PCM, 16 kHz, mono)
        let inputFormat = buffer.format
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * analyzerFormat.sampleRate / inputFormat.sampleRate)
        guard frameCapacity > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var hasData = true
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("SpeechAnalyzer: Conversion error: \(error)")
            return
        }

        // Send converted buffer to analyzer
        inputContinuation?.yield(AnalyzerInput(buffer: convertedBuffer))
    }

    func startTranscribing() {
        isStoppingIntentionally = false
        transcribedText = ""
        baseTranscript = ""
        lastResultLength = 0
        error = nil
        audioConverter = nil // Reset converter for fresh format detection

        // Cancel any previous results loop before starting a new one.
        // Without this, calling startTranscribing() twice would run two loops in parallel,
        // both writing to transcribedText and causing duplication.
        resultsTask?.cancel()
        resultsTask = nil

        Task {
            do {
                print("SpeechAnalyzer: Starting transcription...")

                // Create transcriber using the progressive preset for continuous live audio ingestion
                let newTranscriber = SpeechTranscriber(
                    locale: Locale.current,
                    preset: .progressiveTranscription
                )
                transcriber = newTranscriber

                print("SpeechAnalyzer: Transcriber created")

                // Negotiate the best audio format the neural engine expects — avoids format-mismatch crashes
                if let negotiatedFormat = try? await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [newTranscriber]) {
                    analyzerFormat = negotiatedFormat
                    print("SpeechAnalyzer: Negotiated audio format: \(negotiatedFormat)")
                } else {
                    // Fallback to known-good format if negotiation fails
                    let fallback = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)
                    guard fallback != nil else {
                        await MainActor.run { self.error = "Could not create audio format for transcription." }
                        return
                    }
                    analyzerFormat = fallback
                    print("SpeechAnalyzer: Using fallback audio format 16kHz PCM Int16")
                }

                // Reset converter so appendBuffer() picks up the new format
                audioConverter = nil

                // Create input stream
                let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
                self.inputContinuation = inputContinuation

                print("SpeechAnalyzer: Input stream created")

                // Create analyzer with input sequence
                let newAnalyzer = SpeechAnalyzer(
                    inputSequence: inputSequence,
                    modules: [newTranscriber]
                )
                analyzer = newAnalyzer

                print("SpeechAnalyzer: Analyzer created")

                // Start processing results
                resultsTask = Task { [weak self] in
                    guard let self = self else { return }

                    do {
                        for try await result in newTranscriber.results {
                            let newText = String(result.text.characters)
                            await MainActor.run {
                                // Distinguish a true window slide from a model revision:
                                // - Window slide: the transcriber resets its context and the new result
                                //   is dramatically shorter (typically just the last few seconds of speech)
                                // - Model revision: the model tweaks its hypothesis, text stays similar length
                                //
                                // Using < 50% of previous length as the threshold. Any shorter result
                                // that doesn't meet this bar is treated as a revision and overwrites
                                // the current window without duplicating into baseTranscript.
                                let isWindowSlide = newText.count < (self.lastResultLength / 2) && self.lastResultLength > 20

                                if isWindowSlide && !self.transcribedText.isEmpty {
                                    self.baseTranscript = self.transcribedText
                                }

                                if self.baseTranscript.isEmpty {
                                    self.transcribedText = newText
                                } else {
                                    self.transcribedText = self.baseTranscript + " " + newText
                                }

                                self.lastResultLength = newText.count
                            }
                        }
                    } catch {
                        print("SpeechAnalyzer: Results error: \(error)")
                        await MainActor.run {
                            self.error = "Transcription error: \(error.localizedDescription)"
                        }
                    }
                }

                // Prepare analyzer
                print("SpeechAnalyzer: Preparing analyzer...")
                try await newAnalyzer.prepareToAnalyze(in: nil)
                print("SpeechAnalyzer: Analyzer prepared")

                // Audio buffers will be fed via appendBuffer() from TranscriptionService/SharedAudioManager
                print("SpeechAnalyzer: Ready to receive audio buffers from SharedAudioManager")

                await MainActor.run {
                    self.isTranscribing = true
                }

            } catch {
                print("SpeechAnalyzer: Fatal error: \(error)")
                await MainActor.run {
                    self.error = "Failed to start transcription: \(error.localizedDescription)"
                }
            }
        }
    }

    func pauseTranscribing() {
        // SharedAudioManager handles audio engine pause
    }

    func resumeTranscribing() {
        // SharedAudioManager handles audio engine resume
    }

    func stopTranscribing() {
        isStoppingIntentionally = true

        // Finish input stream
        inputContinuation?.finish()
        inputContinuation = nil

        // Cancel results task
        resultsTask?.cancel()
        resultsTask = nil

        // Clean up converter
        audioConverter = nil

        // Clean up analyzer and transcriber
        Task { @MainActor in
            analyzer = nil
            transcriber = nil
            isTranscribing = false
        }
    }

    func reset() {
        isStoppingIntentionally = true
        stopTranscribing()

        DispatchQueue.main.async {
            self.transcribedText = ""
            self.baseTranscript = ""
            self.lastResultLength = 0
            self.error = nil
        }
    }

    // MARK: - Offline File Transcription

    /// Transcribes a saved audio file using the `.offlineTranscription` preset, which uses full
    /// bidirectional context for higher accuracy than the live progressive pass.
    /// This is a static-style method — it creates its own isolated analyzer and does not
    /// affect any live transcription session in progress.
    func transcribeFile(at fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "SpeechAnalyzerService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio file not found at \(fileURL.path)"])
        }

        // Create an isolated transcriber using the standard transcription preset.
        // This uses a non-streaming evaluation path suitable for pre-recorded files.
        let offlineTranscriber = SpeechTranscriber(
            locale: Locale.current,
            preset: .transcription
        )

        // Negotiate the correct format for the offline model
        let targetFormat: AVAudioFormat
        if let negotiated = try? await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [offlineTranscriber]) {
            targetFormat = negotiated
        } else if let fallback = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false) {
            targetFormat = fallback
        } else {
            throw NSError(domain: "SpeechAnalyzerService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create audio format for offline transcription"])
        }

        // Build the input stream
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        let offlineAnalyzer = SpeechAnalyzer(
            inputSequence: inputSequence,
            modules: [offlineTranscriber]
        )

        let audioFormatHint: AVAudioFormat? = nil
        try await offlineAnalyzer.prepareToAnalyze(in: audioFormatHint)

        // Collect the final result before we start feeding audio
        async let transcriptTask: String = {
            var fullText = ""
            do {
                for try await result in offlineTranscriber.results {
                    // Offline preset emits a single finalized result at the end
                    fullText = String(result.text.characters)
                }
            } catch {
                print("SpeechAnalyzerService offline: results error: \(error)")
            }
            return fullText
        }()

        // Read the audio file and feed it into the analyzer
        let audioFile = try AVAudioFile(forReading: fileURL)
        let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat)

        let readBufferSize: AVAudioFrameCount = 4096
        let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: readBufferSize)!

        while audioFile.framePosition < audioFile.length {
            let framesToRead = min(readBufferSize, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
            readBuffer.frameLength = framesToRead
            try audioFile.read(into: readBuffer, frameCount: framesToRead)

            // Convert to the target format
            let outputCapacity = AVAudioFrameCount(Double(framesToRead) * targetFormat.sampleRate / audioFile.processingFormat.sampleRate) + 1
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { continue }

            var hasData = true
            converter?.convert(to: convertedBuffer, error: nil) { _, outStatus in
                if hasData {
                    hasData = false
                    outStatus.pointee = .haveData
                    return readBuffer
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
        }

        // Signal end of audio — triggers finalization of the offline model
        inputContinuation.finish()

        let result = await transcriptTask
        return result
    }
}
