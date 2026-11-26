import AVFoundation
import Foundation

/// What the recorder writes: 16 kHz mono (all Whisper needs). In progress as 16-bit PCM CAF, which stays
/// readable when cut off by a crash; finished as AAC in an .m4a (~15 MB per hour).
public enum AudioFormat {
    public static let sampleRate: Double = 16_000

    /// In memory (AVAudioFile's processing format).
    public static var processing: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// The CAF while recording.
    public static var pcmSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }

    /// The kept .m4a.
    public static var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
    }

    /// Seconds of audio in a file (0 if unreadable).
    public static func duration(of url: URL) -> TimeInterval {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// CAF → .m4a, written to a temporary name and moved into place when complete.
    public static func encodeM4A(from src: URL, to dest: URL) throws {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.deletingPathExtension().lastPathComponent).part.m4a")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let input = try AVAudioFile(forReading: src)
            let output = try AVAudioFile(forWriting: tmp, settings: aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000 * 10) else {
                throw NSError(domain: "oton", code: 1, userInfo: [NSLocalizedDescriptionKey: "no buffer"])
            }
            while input.framePosition < input.length {
                try input.read(into: buf)
                if buf.frameLength == 0 { break }
                try output.write(from: buf)
            }
        }   // both files close here
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

public func peakDB(_ samples: UnsafeBufferPointer<Float>) -> Float {
    var peak: Float = 0
    for s in samples { peak = max(peak, abs(s)) }
    return peak > 0 ? max(-120, 20 * log10(peak)) : -120
}
