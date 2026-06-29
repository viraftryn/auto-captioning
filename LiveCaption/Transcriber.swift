import Foundation
import WhisperKit

/// One transcript line with its time range.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
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

            segments = results
                .flatMap(\.segments)
                .map { TranscriptSegment(start: Double($0.start),
                                         end: Double($0.end),
                                         text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.text.isEmpty }
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
