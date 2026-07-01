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

/// Wraps WhisperKit (CoreML + Neural Engine). Loads a Whisper model on first use
/// and transcribes an in-memory 16 kHz mono buffer to timestamped segments.
///
/// Defaults to a stock multilingual model with language forced to Indonesian.
/// To use a fine-tuned `whisper-*-id` model, convert it to CoreML with
/// whisperkittools and pass its folder name / path as `modelName`.
@MainActor
final class Transcriber: ObservableObject {
    enum Status: Equatable {
        case idle, loadingModel, ready, transcribing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var segments: [TranscriptSegment] = []

    private var pipe: WhisperKit?
    private let modelName: String

    init(modelName: String = "openai_whisper-small") {
        self.modelName = modelName
    }

    var isBusy: Bool {
        switch status {
        case .loadingModel, .transcribing: return true
        default: return false
        }
    }

    var allWords: [TranscriptWord] { segments.flatMap(\.words) }

    func transcribe(_ samples: [Float], language: String = "id") async {
        guard !samples.isEmpty else { return }
        segments = []
        do {
            if pipe == nil {
                status = .loadingModel
                pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
            }
            guard let pipe else { return }

            status = .transcribing
            let options = DecodingOptions(language: language, wordTimestamps: true)
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

            segments = results.flatMap(\.segments).compactMap { segment -> TranscriptSegment? in
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
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Strip Whisper special tokens like `<|startoftranscript|>`, `<|id|>`, and
    /// the timestamp tokens `<|3.20|>`.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
