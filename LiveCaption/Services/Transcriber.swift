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

/// Selectable Whisper model size. Each case maps to a folder in WhisperKit's
/// default CoreML model repo (`argmaxinc/whisperkit-coreml`), downloaded and
/// cached on first use. Bigger = more accurate but slower and a larger download.
enum WhisperModelSize: String, CaseIterable, Identifiable {
    case base, small, medium, large
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base:   return "Base"
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }

    /// Model folder name in the WhisperKit repo.
    var repoName: String {
        switch self {
        case .base:   return "openai_whisper-base"
        case .small:  return "openai_whisper-small"
        case .medium: return "openai_whisper-medium"
        case .large:  return "openai_whisper-large-v3"
        }
    }

    /// Speed/accuracy hint shown next to the picker.
    var hint: String {
        switch self {
        case .base:   return "fastest · lowest accuracy"
        case .small:  return "balanced"
        case .medium: return "slower · higher accuracy"
        case .large:  return "slowest · best accuracy · large download"
        }
    }
}

/// Wraps WhisperKit (CoreML + Neural Engine). Loads the selected Whisper model on
/// first use (and reloads when the size changes), then transcribes an in-memory
/// 16 kHz mono buffer to timestamped segments — language forced to Indonesian by
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

    @Published private(set) var status: Status = .idle
    /// Changing size drops the cached pipeline so the next transcribe reloads it.
    @Published var model: WhisperModelSize {
        didSet { if oldValue != model { pipe = nil; loaded = nil } }
    }

    private var pipe: WhisperKit?
    private var loaded: WhisperModelSize?

    init(model: WhisperModelSize = .small) {
        self.model = model
    }

    var isBusy: Bool {
        switch status {
        case .loadingModel, .transcribing: return true
        default: return false
        }
    }

    /// Transcribe one buffer and return its cleaned segments. Reloads the
    /// WhisperKit pipeline first if the selected model changed since the last run.
    /// Returns an empty array on empty input or failure (see `status`).
    func transcribe(_ samples: [Float], language: String = "id") async -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }
        do {
            if pipe == nil || loaded != model {
                status = .loadingModel
                pipe = try await WhisperKit(WhisperKitConfig(model: model.repoName))
                loaded = model
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
