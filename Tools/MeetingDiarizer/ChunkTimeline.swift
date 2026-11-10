import Foundation

/// 把會議的多個段檔依各自的 `offset`（整場會議的相對秒數）放回同一條時間軸。
///
/// 為什麼要補靜音：錄音器每 5 分鐘停止再重啟，段與段之間約有 0.3–0.5 秒沒錄到。
/// 如果只是把各段音訊接起來，後面的時間會一路往前漂（12 段約漂 5 秒），
/// 說話者辨識的時間就對不上 Groq 逐字稿的時間。
///
/// 警告與錯誤裡的 "manifest entry N" 是該段在 manifest 裡的位置（從 1 起算），**不是**段檔名的編號 NNN
/// （兩者通常相同，但時間軸不依賴檔名編號：只看 offset）。
///
/// 輸入：每段已解碼的 16 kHz 單聲道樣本與 offset。輸出：整場樣本（缺口補 0）。
/// 純函式，不碰檔案、不碰 sherpa。
enum ChunkTimeline {
    struct Chunk {
        let samples: [Float]
        let offset: TimeInterval
    }

    struct Result {
        let samples: [Float]
        /// 整場結束時間（秒）。
        let duration: TimeInterval
        let warnings: [String]
    }

    enum TimelineError: Error, CustomStringConvertible {
        case invalidOffset(Int, TimeInterval)
        case tooLong(TimeInterval)

        var description: String {
            switch self {
            case .invalidOffset(let index, let offset): return "manifest entry \(index + 1) has an invalid offset (\(offset))"
            case .tooLong(let seconds): return "meeting timeline would be \(Int(seconds)) s, over the \(Int(ChunkTimeline.maximumSeconds)) s limit"
            }
        }
    }

    /// 防呆：offset 打錯（例如把毫秒當秒）時不要配置數十 GB 的記憶體。12 小時 × 16 kHz × 4 位元組 ≈ 2.8 GB 仍嫌大，
    /// 但會議功能的實際上限由呼叫端決定；這裡只擋明顯的錯誤。
    static let maximumSeconds: TimeInterval = 12 * 3600

    /// - Parameter chunks: 依 offset 由小到大處理（呼叫端不用先排序，這裡會穩定排序）。
    /// - 重疊（後一段的 offset 早於前一段的結尾）：**保住後面音訊的時間位置**，丟掉後一段開頭重疊的部分並記警告。
    static func assemble(_ chunks: [Chunk], sampleRate: Int) throws -> Result {
        for (index, chunk) in chunks.enumerated() where !chunk.offset.isFinite || chunk.offset < 0 {
            throw TimelineError.invalidOffset(index, chunk.offset)
        }
        let ordered = chunks.enumerated().sorted {
            $0.element.offset != $1.element.offset ? $0.element.offset < $1.element.offset : $0.offset < $1.offset
        }

        var samples: [Float] = []
        var warnings: [String] = []
        for (index, chunk) in ordered {
            let start = Int((chunk.offset * Double(sampleRate)).rounded())
            let end = start + chunk.samples.count
            if Double(end) / Double(sampleRate) > maximumSeconds {
                throw TimelineError.tooLong(Double(end) / Double(sampleRate))
            }
            if start >= samples.count {
                samples.append(contentsOf: repeatElement(0, count: start - samples.count))
                samples.append(contentsOf: chunk.samples)
            } else {
                let skip = samples.count - start
                if skip >= chunk.samples.count {
                    warnings.append("manifest entry \(index + 1) lies entirely inside earlier audio and was dropped")
                } else {
                    warnings.append("manifest entry \(index + 1) overlaps earlier audio by \(Double(skip) / Double(sampleRate)) s; the overlapping head was dropped")
                    samples.append(contentsOf: chunk.samples[skip...])
                }
            }
        }
        return Result(samples: samples, duration: Double(samples.count) / Double(sampleRate), warnings: warnings)
    }
}
