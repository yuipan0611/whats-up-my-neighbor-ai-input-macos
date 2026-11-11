import CryptoKit
import Foundation

/// 下載並安裝說話者辨識模型（`MeetingDiarizerModelCatalog` 裡還沒安裝的那幾個）。
///
/// 安全性與可靠性：
/// - 每個檔案先下載到 models 資料夾內的暫存資料夾，串流計算 SHA256，與程式裡寫死的值比對；不符就丟掉。
/// - tar.bz2 先驗壓縮檔，解出模型檔後再驗一次模型檔的 SHA256 與大小。
/// - 最後用同一個磁碟區內的 rename 搬到正式位置（原子），中途失敗時不會留下半截的模型檔。
/// - 只下載還沒安裝的模型；全部都在就不連網。失敗後再呼叫 `start` 就是重試（已裝好的不重下載）。
/// - 只接受 https，包含轉址。
///
/// `progress` 與 `completion` 都在主執行緒呼叫。
final class MeetingDiarizerDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case http(Int)
        case network(String)
        case sizeMismatch(model: String, expected: Int64, actual: Int64)
        case checksumMismatch(model: String)
        case badArchive(model: String, detail: String)
        case installFailed(String)
        case insecureRedirect
        case insecureURL(model: String)
        case alreadyRunning
        case cancelled

        var errorDescription: String? {
            switch self {
            case .http(let code): return "伺服器回應錯誤（HTTP \(code)）。"
            case .network(let message): return "下載失敗：\(message)"
            case .sizeMismatch(let model, _, _): return "「\(model)」的檔案大小不符，已丟棄。"
            case .checksumMismatch(let model): return "「\(model)」的 SHA256 驗證不符，已丟棄，沒有安裝。"
            case .badArchive(let model, let detail): return "「\(model)」的壓縮檔無法使用：\(detail)"
            case .installFailed(let message): return "無法安裝模型：\(message)"
            case .insecureRedirect: return "下載被導向非 https 的位置，已中止。"
            case .insecureURL(let model): return "「\(model)」的下載網址不是 https，已中止。"
            case .alreadyRunning: return "已經在下載中。"
            case .cancelled: return "已取消下載。"
            }
        }
    }

    struct Progress: Equatable {
        let receivedBytes: Int64
        let totalBytes: Int64
        let modelName: String
        var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 1 }
    }

    typealias Extractor = (_ archive: URL, _ member: String, _ directory: URL) throws -> Void

    private let assets: MeetingDiarizerAssets
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let extract: Extractor
    /// 所有狀態只在這個序列佇列上存取（也是 URLSession 的 delegate queue）。
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "MeetingDiarizerDownloader"
        return queue
    }()

    private final class Run {
        var models: [MeetingDiarizerModel]
        let totalBytes: Int64
        var completedBytes: Int64 = 0
        let staging: URL
        let session: URLSession
        let progress: (Progress) -> Void
        let completion: (Result<Void, Failure>) -> Void
        var failure: Failure?
        var cancelled = false
        var finished = false
        var lastReported: Double = -1
        var current: Current?

        init(models: [MeetingDiarizerModel], staging: URL, session: URLSession,
             progress: @escaping (Progress) -> Void, completion: @escaping (Result<Void, Failure>) -> Void) {
            self.models = models
            self.totalBytes = models.reduce(0) { $0 + $1.downloadBytes }
            self.staging = staging
            self.session = session
            self.progress = progress
            self.completion = completion
        }
    }

    private final class Current {
        let model: MeetingDiarizerModel
        let partURL: URL
        let handle: FileHandle
        var hasher = SHA256()
        var received: Int64 = 0
        var task: URLSessionDataTask?
        init(model: MeetingDiarizerModel, partURL: URL, handle: FileHandle) {
            self.model = model
            self.partURL = partURL
            self.handle = handle
        }
    }

    private var run: Run?

    init(assets: MeetingDiarizerAssets = MeetingDiarizerAssets(),
         configuration: URLSessionConfiguration = .ephemeral,
         fileManager: FileManager = .default,
         extract: @escaping Extractor = MeetingDiarizerDownloader.extractWithTar) {
        self.assets = assets
        self.configuration = configuration
        self.fileManager = fileManager
        self.extract = extract
    }

    // MARK: 公開操作

    func start(progress: @escaping (Progress) -> Void, completion: @escaping (Result<Void, Failure>) -> Void) {
        queue.addOperation { [self] in
            guard run == nil else {
                DispatchQueue.main.async { completion(.failure(.alreadyRunning)) }
                return
            }
            let missing = assets.missingModels()
            guard !missing.isEmpty else {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            removeStaleStaging()
            let staging = assets.modelsDirectory.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
            do { try fileManager.createDirectory(at: staging, withIntermediateDirectories: true) }
            catch {
                DispatchQueue.main.async { completion(.failure(.installFailed(error.localizedDescription))) }
                return
            }
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let newRun = Run(models: missing, staging: staging, session: session, progress: progress, completion: completion)
            run = newRun
            beginNextModel(newRun)
        }
    }

    func cancel() {
        queue.addOperation { [self] in
            guard let run, !run.finished else { return }
            run.cancelled = true
            if let task = run.current?.task { task.cancel() } else { finish(run, failure: .cancelled) }
        }
    }

    // MARK: 流程

    private func beginNextModel(_ run: Run) {
        guard !run.finished else { return }
        guard let model = run.models.first else { finish(run, failure: nil); return }
        // 起始網址也必須是 https（轉址在 delegate 裡另外檢查）。
        guard model.url.scheme?.lowercased() == "https" else { finish(run, failure: .insecureURL(model: model.name)); return }
        let partURL = run.staging.appendingPathComponent("download-\(run.models.count).part")
        do {
            fileManager.createFile(atPath: partURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partURL)
            let current = Current(model: model, partURL: partURL, handle: handle)
            run.current = current
            var request = URLRequest(url: model.url)
            request.timeoutInterval = 60
            let task = run.session.dataTask(with: request)
            current.task = task
            task.resume()
        } catch {
            finish(run, failure: .installFailed(error.localizedDescription))
        }
    }

    private func finishCurrentModel(_ run: Run, _ current: Current) {
        try? current.handle.close()
        let model = current.model
        if current.received != model.downloadBytes {
            finish(run, failure: .sizeMismatch(model: model.name, expected: model.downloadBytes, actual: current.received))
            return
        }
        let digest = current.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == model.downloadSHA256 else {
            finish(run, failure: .checksumMismatch(model: model.name))
            return
        }
        do {
            try install(model, downloaded: current.partURL, staging: run.staging)
        } catch let failure as Failure {
            finish(run, failure: failure)
            return
        } catch {
            finish(run, failure: .installFailed(error.localizedDescription))
            return
        }
        run.completedBytes += model.downloadBytes
        run.models.removeFirst()
        run.current = nil
        report(run, received: 0, name: model.name, force: true)
        beginNextModel(run)
    }

    /// 驗證、再用 rename 搬到正式位置。來源與目的地在同一個 models 資料夾內（同一個磁碟區），所以是原子的。
    private func install(_ model: MeetingDiarizerModel, downloaded: URL, staging: URL) throws {
        let source: URL
        switch model.source {
        case .file:
            source = downloaded
        case .archive(let member):
            let directory = staging.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
            do { try extract(downloaded, member, directory) }
            catch { throw Failure.badArchive(model: model.name, detail: error.localizedDescription) }
            source = directory.appendingPathComponent(member)
            guard fileManager.fileExists(atPath: source.path) else {
                throw Failure.badArchive(model: model.name, detail: "壓縮檔裡沒有 \(member)")
            }
        }
        let size = (try? fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == model.installedBytes else {
            throw Failure.sizeMismatch(model: model.name, expected: model.installedBytes, actual: size)
        }
        guard (try? Self.sha256(of: source)) == model.installedSHA256 else {
            throw Failure.checksumMismatch(model: model.name)
        }
        let destination = assets.installedURL(for: model)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            throw Failure.installFailed(error.localizedDescription)
        }
    }

    private func finish(_ run: Run, failure: Failure?) {
        guard !run.finished else { return }
        run.finished = true
        try? run.current?.handle.close()
        run.current = nil
        SafeFileRemoval.removeOwnedStaging(run.staging, within: assets.modelsDirectory)
        run.session.invalidateAndCancel()
        self.run = nil
        let result: Result<Void, Failure> = failure.map { .failure($0) } ?? .success(())
        DispatchQueue.main.async { run.completion(result) }
    }

    private func report(_ run: Run, received: Int64, name: String, force: Bool = false) {
        let value = Progress(receivedBytes: run.completedBytes + received, totalBytes: run.totalBytes, modelName: name)
        // 不要每個封包都通知 UI：變化至少 0.5% 才送，最後一定送。
        guard force || value.fraction - run.lastReported >= 0.005 else { return }
        run.lastReported = value.fraction
        DispatchQueue.main.async { run.progress(value) }
    }

    private func removeStaleStaging() {
        let names = (try? fileManager.contentsOfDirectory(atPath: assets.modelsDirectory.path)) ?? []
        for name in names where SafeFileRemoval.isStagingName(name) {
            SafeFileRemoval.removeOwnedStaging(assets.modelsDirectory.appendingPathComponent(name), within: assets.modelsDirectory)
        }
    }

    // MARK: URLSessionDataDelegate（都在 `queue` 上）

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let run, let current = run.current, current.task === dataTask else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if run.failure == nil { run.failure = .http(http.statusCode) }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let run, let current = run.current, current.task === dataTask, run.failure == nil else { return }
        do {
            try current.handle.write(contentsOf: data)
        } catch {
            run.failure = .installFailed(error.localizedDescription)
            dataTask.cancel()
            return
        }
        current.hasher.update(data: data)
        current.received += Int64(data.count)
        // 收到的比預期多：不用等下載完，直接中止。
        if current.received > current.model.downloadBytes {
            run.failure = .sizeMismatch(model: current.model.name, expected: current.model.downloadBytes, actual: current.received)
            dataTask.cancel()
            return
        }
        report(run, received: current.received, name: current.model.name)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let run, let current = run.current, current.task === task else { return }
        if let failure = run.failure { finish(run, failure: failure); return }
        if run.cancelled { finish(run, failure: .cancelled); return }
        if let error { finish(run, failure: .network(error.localizedDescription)); return }
        finishCurrentModel(run, current)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else {
            // 不跟隨、也不處理那個 3xx 的內容：直接中止，結果以 .insecureRedirect 回報。
            run?.failure = .insecureRedirect
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    // MARK: 工具

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 用系統的 /usr/bin/tar 只解出一個成員。壓縮檔的 SHA256 已先驗過，所以內容是可信的。
    static func extractWithTar(archive: URL, member: String, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path, member]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.badArchive(model: "", detail: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
