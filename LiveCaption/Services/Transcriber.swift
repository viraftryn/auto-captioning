import Foundation
import WhisperKit

/// One word with its time range.
struct TranscriptWord {
    let text: String
    let start: Double
    let end: Double
}

/// One transcript line with its time range and word timings.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
    let words: [TranscriptWord]
}

/// Wraps WhisperKit (CoreML + Neural Engine). Always transcribes with Whisper
/// `large-v3`: on the Neural Engine its inference stays fast enough for this app
/// while giving the best accuracy, so the model is fixed rather than selectable. The
/// model is downloaded from WhisperKit's default CoreML repo
/// (`argmaxinc/whisperkit-coreml`) and cached on first use, then reused for every
/// transcribe of an in-memory 16 kHz mono buffer — language forced to Indonesian by
/// default.
///
/// In the Analyze-File pipeline this runs **per separated stream**: SepFormer
/// splits the mixture into one clean waveform per speaker, and each is transcribed
/// on its own, so the resulting words already belong to a known speaker.
@MainActor
final class Transcriber: ObservableObject {
    enum Status: Equatable {
        case idle, loadingModel, ready, transcribing
        case failed(String)
    }

    /// WhisperKit model folder in the `argmaxinc/whisperkit-coreml` repo.
    static let modelRepo = "openai_whisper-large-v3"

    @Published private(set) var status: Status = .idle
    private var pipe: WhisperKit?

    var isBusy: Bool {
        switch status {
        case .loadingModel, .transcribing: return true
        default: return false
        }
    }

    /// Transcribe one buffer and return its cleaned segments. Loads the WhisperKit
    /// pipeline on first use. Returns an empty array on empty input or failure (see
    /// `status`).
    func transcribe(_ samples: [Float], language: String = "id") async -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }
        do {
            if pipe == nil {
                status = .loadingModel
                pipe = try await WhisperKit(WhisperKitConfig(model: Self.modelRepo))
            }
            guard let pipe else { return [] }

            status = .transcribing
            let options = DecodingOptions(language: language, wordTimestamps: true)
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

            let segments = results.flatMap(\.segments).compactMap { segment -> TranscriptSegment? in
                let text = Self.clean(segment.text)
                guard !text.isEmpty else { return nil }
                var words = (segment.words ?? []).compactMap { word -> TranscriptWord? in
                    let cleaned = Self.clean(word.word)
                    guard !cleaned.isEmpty else { return nil }
                    return TranscriptWord(text: cleaned, start: Double(word.start), end: Double(word.end))
                }
                if words.isEmpty {
                    words = [TranscriptWord(text: text, start: Double(segment.start), end: Double(segment.end))]
                }
                return TranscriptSegment(start: Double(segment.start), end: Double(segment.end),
                                         text: text, words: words)
            }
            status = .ready
            return segments
        } catch {
            status = .failed(error.localizedDescription)
            return []
        }
    }

    /// Strip Whisper special tokens like `<|startoftranscript|>`, `<|id|>`, and
    /// the timestamp tokens `<|3.20|>`.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
