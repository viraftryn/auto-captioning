import Foundation

/// A run of words attributed to one speaker (or none).
struct AttributedUtterance: Identifiable {
    let id = UUID()
    let speaker: Int?
    let text: String
    let start: Double
    let end: Double
}

/// Word → face attribution: assign each transcribed word to the face that was
/// moving most at that instant (from the video timeline), then merge consecutive
/// same-speaker words into utterances. This is the "Attribution · word → face"
/// node that produces the speaker-attributed transcript.
enum Attribution {
    static func attribute(words: [TranscriptWord],
                          timeline: VideoAnalyzer.Timeline,
                          threshold: Double) -> [AttributedUtterance] {
        var result: [AttributedUtterance] = []
        for word in words {
            let mid = (word.start + word.end) / 2
            let speaker = timeline.dominantSpeaker(at: mid, threshold: threshold)
            if let last = result.last, last.speaker == speaker {
                result[result.count - 1] = AttributedUtterance(
                    speaker: speaker,
                    text: last.text + " " + word.text,
                    start: last.start,
                    end: word.end)
            } else {
                result.append(AttributedUtterance(speaker: speaker, text: word.text,
                                                  start: word.start, end: word.end))
            }
        }
        return result
    }
}
