# Changelog

## 2026-03-03
Reordered post-recording pipeline so on-device offline transcript pass completes before AI notes and flashcards are generated. Notes now always use the improved transcript, not the raw live one.

## 2026-03-03
Fixed transcript duplication bug: the accumulation heuristic was treating every minor model revision as a window slide, saving the transcript to baseTranscript and appending again. Fixed by requiring the result to be less than 50% of the previous length before treating it as a true reset. Also fixed a secondary bug where calling startTranscribing() twice would leave two results loops running in parallel.

## 2026-03-03
Added on-device SpeechAnalyzer offline transcript upgrade that runs automatically after every live recording (replacing legacy SFSpeechRecognizer). Added manual "Improve Transcript" button in the detail view that uploads audio to Gemini 2.5 Flash for the highest-quality transcript with punctuation and speaker labels (~$0.07/hr). Updated CLAUDE.md to require generating a Gemini Deep Research prompt whenever an API or SDK needs research before implementation.

## 2026-03-03
Added Gemini audio transcription pipeline: after recording stops, the M4A file is uploaded to Gemini 2.5 Flash via the Files API to produce a high-quality transcript with punctuation, capitalization, and speaker labels (~$0.07/hr). Also improved SpeechAnalyzerService to use `bestAvailableAudioFormat` for dynamic format negotiation instead of hardcoded 16kHz PCM, reducing format-mismatch crashes. Reset TCC permissions to fix the app crash on Record tap.

## 2026-03-02
Added XCUITest target with 7 UI tests covering app launch, main window, settings, recording detail tabs, and the Regenerate AI Notes button. Added autonomous development workflow to CLAUDE.md so builds, code reviews, and tests run automatically after every change.

## 2026-03-02
Added "Regenerate AI Notes" button to the recording detail view, allowing students to retry AI note generation for recordings where it failed (e.g. closed laptop, bad API key). Fixed live UI updates after regeneration by switching SDRecording bindings to `@Bindable` in detail, summary, and recall views.

## 2026-03-02
Updated CLAUDE.md to reflect macOS 26 deployment target and SpeechAnalyzer API details. Removed `@available(macOS 26.0, *)` annotation from SpeechAnalyzerService (redundant given min target). Deleted stale CHANGELOG.md and convert-docs.py scripts.
