import AVFoundation
import AudioToolbox
import Foundation
import OtonCore

/// Writes one recording (16 kHz mono CAF). The mic can be swapped while recording: each `attach` opens a fresh
/// AVAudioEngine on that device and keeps appending to the same file.
final class Recorder {
    let url: URL
    private let queue = DispatchQueue(label: "oton.recorder")
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0      // on `queue`
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private(set) var device: InputDevice?
    private(set) var lastPeakDB: Float = -120
    /// The engine stopped on its own (device format change, device gone). Main queue.
    var onInterrupted: (() -> Void)?
    var onError: ((String) -> Void)?

    init(url: URL) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: AudioFormat.pcmSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Seconds written so far: where the next segment starts in the file.
    var writtenSeconds: TimeInterval { queue.sync { Double(framesWritten) / AudioFormat.sampleRate } }
    var isAttached: Bool { engine != nil }

    func attach(_ dev: InputDevice) throws {
        detach()
        let eng = AVAudioEngine()
        let input = eng.inputNode
        // Bind this engine's input to our device, independent of the macOS default input.
        guard let au = input.audioUnit else { throw err("no audio unit") }
        var devID = dev.id
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else { throw err("cannot select \(dev.name) (\(st))") }
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw err("\(dev.name) has no usable input format") }
        guard let conv = AVAudioConverter(from: inFormat, to: AudioFormat.processing) else { throw err("no converter for \(inFormat)") }
        conv.downmix = true
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in self?.handle(buf, conv) }
        eng.prepare()
        do { try eng.start() } catch {
            input.removeTap(onBus: 0)
            throw err("\(dev.name): \(error.localizedDescription)")
        }
        // Opening a device itself posts a configuration change, so react only if the engine actually stopped
        // (checked a moment later); re-opening on every notification loops forever and the mic flickers.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng, queue: .main) { [weak self, weak eng] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self, let eng, self.engine === eng, !eng.isRunning else { return }
                self.onInterrupted?()
            }
        }
        engine = eng
        converter = conv
        device = dev
    }

    func detach() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        converter = nil
        device = nil
        queue.sync {}   // let pending writes land
    }

    /// Stops and closes the file (AVAudioFile finalizes the header on deinit).
    func finish() {
        detach()
        queue.sync { file = nil }
    }

    private func handle(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter) {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * AudioFormat.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioFormat.processing, frameCapacity: cap) else { return }
        var fed = false
        var e: NSError?
        conv.convert(to: out, error: &e) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard e == nil, out.frameLength > 0 else { return }
        let peak = peakDB(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        queue.async { [weak self] in
            guard let self, let file = self.file else { return }
            self.lastPeakDB = peak
            do {
                try file.write(from: out)
                self.framesWritten += AVAudioFramePosition(out.frameLength)
            } catch {
                let msg = "write failed: \(error)"
                DispatchQueue.main.async { self.onError?(msg) }
            }
        }
    }

    private func err(_ msg: String) -> NSError { NSError(domain: "oton", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
}
