import Foundation
import AVFoundation

/// Tiene viva l'app in background con un audio silenzioso (come fanno le app di navigazione),
/// così il percorso continua e le notifiche partono anche a telefono bloccato.
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWav())
            p.numberOfLoops = -1
            p.prepareToPlay()
            p.play()
            player = p
        } catch {}
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Un secondo di silenzio (WAV 8 kHz, 16 bit, mono).
    private static func silentWav() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize = Int(sampleRate) * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        d.append(Data(count: dataSize))
        return d
    }
}
