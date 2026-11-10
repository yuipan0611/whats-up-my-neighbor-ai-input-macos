import AVFoundation
import Foundation

/// 把任何 AVFoundation 能讀的音檔（m4a/AAC、wav、caf…）解碼成
/// sherpa-onnx 要的格式：16 kHz、單聲道、Float32（-1…1）。
///
/// 輸入：音檔路徑。輸出：`[Float]`。
/// 以分批方式讀取，不會一次配置整個檔案大小的 buffer。
enum AudioPCMReader {
    enum ReaderError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case cannotCreateConverter
        case conversionFailed(String)

        var description: String {
            switch self {
            case .cannotOpen(let message): return "cannot open audio file: \(message)"
            case .cannotCreateConverter: return "cannot create audio converter"
            case .conversionFailed(let message): return "audio conversion failed: \(message)"
            }
        }
    }

    static let targetSampleRate: Double = 16_000
    private static let chunkFrames: AVAudioFrameCount = 16_000 * 30

    static func readMono16k(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ReaderError.cannotOpen(error.localizedDescription)
        }

        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw ReaderError.cannotCreateConverter }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ReaderError.cannotCreateConverter
        }

        var samples: [Float] = []
        let estimated = Double(file.length) / inputFormat.sampleRate * targetSampleRate
        if estimated.isFinite, estimated > 0 { samples.reserveCapacity(Int(estimated) + 1) }

        var readError: Error?
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkFrames) else {
                throw ReaderError.cannotCreateConverter
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                // 讀過檔尾 AVAudioFile 會丟 OSStatus -39，所以先算剩餘影格數。
                let remaining = file.length - file.framePosition
                guard remaining > 0,
                      let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: requested) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(requested), remaining)))
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }

            if let readError { throw ReaderError.conversionFailed(readError.localizedDescription) }
            if status == .error {
                throw ReaderError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
            }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
        }
        return samples
    }
}
