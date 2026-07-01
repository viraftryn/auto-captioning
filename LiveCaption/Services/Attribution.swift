import Foundation

/// A run of words attributed to one speaker (or none), rendered as one line in
/// the speaker-attributed transcript.
///
/// Attribution now comes from **source separation**: SepFormer splits the mix
/// into one clean waveform per speaker (each matched to a face via active-speaker
/// correlation — see `SourceAssignment`), each stream is transcribed on its own,
/// and every segment is tagged with that stream's speaker. The merge/order/label
/// step lives in `AnalysisViewModel.setPerSpeakerTranscript`.
struct AttributedUtterance: Identifiable {
    let id = UUID()
    let speaker: Int?
    let text: String
    let start: Double
    let end: Double
}
