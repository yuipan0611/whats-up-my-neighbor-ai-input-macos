import Foundation

/// 用 `Process` 執行 `meeting-diarizer`（獨立程式：當機或簽章問題不會拖垮 App）。
///
/// 執行緒模型：`run` 與所有回呼都在主執行緒；Process 與讀 pipe 在背景佇列。
/// 一把 `NSLock` 保護 `process` 與 `cancelled`：`cancel()` 在鎖內把 `cancelled` 設成 true 並取出 process，
/// **解鎖之後**才 `terminate()`（不在鎖內呼叫外部程式碼）；背景完成時在同一把鎖內讀 `cancelled`，
/// 已取消就不回呼，所以取消之後不會再有任何回呼或寫檔。
final class ProcessDiarizerRunner: DiarizerProcessRunning {
    func run(executable: URL, arguments: [String],
             onProgress: @escaping (Int, Int) -> Void,
             completion: @escaping (Result<DiarizerRunResult, Error>) -> Void) -> DictationCancellable {
        dispatchPrecondition(condition: .onQueue(.main))
        let job = Job()
        DispatchQueue.global(qos: .userInitiated).async {
            job.execute(executable: executable, arguments: arguments, onProgress: onProgress, completion: completion)
        }
        return job
    }

    final class Job: DictationCancellable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func cancel() {
            dispatchPrecondition(condition: .onQueue(.main))
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            running?.terminate()
        }

        private var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func execute(executable: URL, arguments: [String],
                     onProgress: @escaping (Int, Int) -> Void,
                     completion: @escaping (Result<DiarizerRunResult, Error>) -> Void) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice

            // 已經取消就不啟動。
            if isCancelled { return }

            let progressBuffer = LineBuffer()
            errors.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in progressBuffer.append(data) {
                    guard let progress = Self.parseProgress(line) else { continue }
                    DispatchQueue.main.async {
                        guard !self.isCancelled else { return }
                        onProgress(progress.done, progress.total)
                    }
                }
            }
            do {
                try process.run()
            } catch {
                errors.fileHandleForReading.readabilityHandler = nil
                deliver(.failure(error), completion)
                return
            }
            // process 啟動成功之後才登記：還沒啟動的 Process 不能 terminate（會丟例外）。
            // 登記前就被取消的，由這裡自己終止（解鎖之後）。
            lock.lock()
            self.process = process
            let cancelledEarly = cancelled
            lock.unlock()
            if cancelledEarly { process.terminate() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            errors.fileHandleForReading.readabilityHandler = nil
            let tail = progressBuffer.tail
            deliver(.success(DiarizerRunResult(exitCode: process.terminationStatus, standardOutput: data,
                                               standardError: tail)), completion)
        }

        private func deliver(_ result: Result<DiarizerRunResult, Error>,
                             _ completion: @escaping (Result<DiarizerRunResult, Error>) -> Void) {
            // 強參照：呼叫端不一定留著取消把手，完成回呼不能因為 Job 被釋放而遺失。
            DispatchQueue.main.async {
                guard !self.isCancelled else { return }
                completion(result)
            }
        }

        /// stderr 的 `progress <已完成>/<總數>`。其他行不是進度。
        static func parseProgress(_ line: String) -> (done: Int, total: Int)? {
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0] == "progress" else { return nil }
            let numbers = parts[1].split(separator: "/")
            guard numbers.count == 2, let done = Int(numbers[0]), let total = Int(numbers[1]), total > 0 else { return nil }
            return (done, total)
        }
    }

    /// 把分批到達的 stderr 位元組組成完整的行，並保留最後幾行（失敗時顯示原因用）。
    private final class LineBuffer {
        private let lock = NSLock()
        private var pending = ""
        private var recent: [String] = []

        func append(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            pending += String(decoding: data, as: UTF8.self)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: "\n") {
                lines.append(String(pending[..<newline]))
                pending = String(pending[pending.index(after: newline)...])
            }
            recent.append(contentsOf: lines.filter { !$0.hasPrefix("progress ") })
            if recent.count > 20 { recent.removeFirst(recent.count - 20) }
            return lines
        }

        var tail: String {
            lock.lock(); defer { lock.unlock() }
            return (recent + (pending.isEmpty ? [] : [pending])).joined(separator: "\n")
        }
    }
}
