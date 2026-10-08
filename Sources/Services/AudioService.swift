import Foundation
import AVFoundation

/// 发音服务 - 本地合成 + 网络音频
final class AudioService: NSObject {
    static let shared = AudioService()

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private let session: URLSession

    private override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        super.init()
    }

    // MARK: - 播放单词发音

    func speak(_ word: String, phonetic: String? = nil) {
        // 优先使用网络音频（真人发音）
        // 如果本地已经缓存了音频 URL，直接播放网络音频
        // 否则使用系统 TTS
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB") // 英式发音
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.9

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
    }

    func playAudio(from urlString: String) async {
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await session.data(from: url)
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("[AudioService] 网络音频播放失败: \(error)")
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
    }
}
