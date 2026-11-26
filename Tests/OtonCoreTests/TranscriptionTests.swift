import AVFoundation
import Foundation
import Testing
@testable import OtonCore

/// Writes `active/<id>.caf` the way the recorder does (16 kHz mono 16-bit), from `samples`.
func writeActive(_ paths: Paths, id: String, _ samples: [Float]) throws {
    let file = try AVAudioFile(forWriting: paths.activeAudio(id), settings: AudioFormat.pcmSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: AudioFormat.processing, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    for (i, s) in samples.enumerated() { buf.floatChannelData![0][i] = s }
    try file.write(from: buf)
}

func tone(seconds: Double) -> [Float] { (0..<Int(seconds * 16000)).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 16000) } }

/// Real German speech from macOS `say`, resampled to 16 kHz mono.
func speech(_ text: String, in dir: URL) throws -> [Float] {
    let aiff = dir.appendingPathComponent("say-\(UUID().uuidString).aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Anna", "-o", aiff.path, text]
    try say.run(); say.waitUntilExit()
    let src = try AVAudioFile(forReading: aiff)
    let conv = AVAudioConverter(from: src.processingFormat, to: AudioFormat.processing)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length))!
    try src.read(into: inBuf)
    let outBuf = AVAudioPCMBuffer(pcmFormat: AudioFormat.processing, frameCapacity: AVAudioFrameCount(Double(src.length) * 16000 / src.processingFormat.sampleRate) + 1024)!
    var fed = false
    _ = conv.convert(to: outBuf, error: nil) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return inBuf
    }
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
}

@Suite struct TranscriptionTests {
    @Test func finalizeEncodesAndSplitsSegments() throws {
        let p = try tempPaths()
        defer { cleanup(p) }
        // 30 s on the Samson, sleep 10:00:30–10:05:00, then 30 s on the webcam.
        let st = RecordingState(id: "r1", start: at(10, 0), segments: [
            Segment(outStart: 0, wallStart: at(10, 0), mic: "USB Microphone"),
            Segment(outStart: 30, wallStart: at(10, 5), mic: "HD Web Camera", gapReason: "sleep"),
        ])
        try writeActive(p, id: st.id, tone(seconds: 60))
        try st.save(p)

        let t = Transcriber(paths: p, settings: Settings())
        let job = try t.finalizeRecording(st)
        #expect(job.id == "26-11-26_1000-1005_6m_oton")
        #expect(job.segments.map(\.duration) == [30, 30])
        #expect(job.end == at(10, 5, 30))
        #expect(abs(AudioFormat.duration(of: URL(fileURLWithPath: job.recording)) - 60) < 0.2)
        #expect(job.recording.hasSuffix("/docs/recordings/26-11-26_1000-1005_6m_oton.m4a"))
        #expect(!FileManager.default.fileExists(atPath: p.activeAudio("r1").path))
        #expect(t.pending().map(\.id) == [job.id])
        #expect(gaps(in: job.segments) == [Gap(from: at(10, 0, 30), to: at(10, 5), reason: "sleep")])

        let text = postProcess(wolfgangText: "Transkript von „audio.m4a“\n\n[00:00:02] Erstens.\n\n[00:00:40] Zweitens.\n", job: job)
        #expect(text == """
        oton transcript
        Date: 2026-11-26, 10:00–10:05 (1 min)
        Mic: USB Microphone, then HD Web Camera
        Gaps: 10:00–10:05 (sleep)

        [10:00] Erstens.

        [gap 10:00–10:05, sleep]

        [10:05] Zweitens.

        """)
    }

    @Test func tooShortIsDiscarded() throws {
        let p = try tempPaths()
        defer { cleanup(p) }
        let st = RecordingState(id: "r2", start: at(10, 0), segments: [Segment(outStart: 0, wallStart: at(10, 0), mic: "m")])
        try writeActive(p, id: st.id, tone(seconds: 0.5))
        #expect(throws: OtonError.tooShort) { try Transcriber(paths: p, settings: Settings()).finalizeRecording(st) }
        #expect(RecordingState.leftovers(p).isEmpty)
    }

    @Test func leftoversAreFound() throws {
        let p = try tempPaths()
        defer { cleanup(p) }
        let st = RecordingState(id: "r3", start: at(9, 0), segments: [Segment(outStart: 0, wallStart: at(9, 0), mic: "m")])
        try writeActive(p, id: st.id, tone(seconds: 2))
        try st.save(p)
        try writeActive(p, id: "r4", tone(seconds: 2))   // CAF without JSON
        #expect(RecordingState.leftovers(p).map(\.id) == ["r3", "r4"])
        #expect(RecordingState.leftovers(p, excluding: "r4") == [st])
    }

    /// Real speech through the real Wolfgang. Skipped if Wolfgang isn't installed.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/local/bin/wolfgang")))
    func endToEndWithWolfgang() throws {
        let p = try tempPaths()
        defer { cleanup(p) }
        let words = try speech("Wir müssen bis Freitag das Angebot fertig machen.", in: p.support)
        let st = RecordingState(id: "r5", start: at(10, 40, 5), segments: [Segment(outStart: 0, wallStart: at(10, 40, 5), mic: "USB Microphone")])
        try writeActive(p, id: st.id, [Float](repeating: 0, count: 8000) + words + [Float](repeating: 0, count: 8000))
        let t = Transcriber(paths: p, settings: Settings())
        let job = try t.finalizeRecording(st)
        let url = try t.run(job)
        let text = try String(contentsOf: url, encoding: .utf8)
        print(text)
        #expect(url.lastPathComponent == "26-11-26_1040-1040_1m_oton.txt")
        #expect(text.hasPrefix("oton transcript\nDate: 2026-11-26, 10:40–10:40"))
        #expect(text.contains("[10:40] Wir müssen bis Freitag"))
        #expect(!FileManager.default.fileExists(atPath: t.workDir(job.id).path))
        #expect(FileManager.default.fileExists(atPath: job.recording))
        #expect(t.pending().isEmpty)
    }
}
