import CryptoKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// MARK: 假伺服器

/// 假的 GitHub：依路徑回應。不碰真網路、不需要任何金鑰。
private final class FakeServer: URLProtocol {
    enum Behavior {
        case body(Data)
        case status(Int)
        case partialThenFail(Data)   // 送出一半資料後連線中斷
        case hold                    // 不回應，直到被 stopLoading
        case redirect(String)
    }
    static let lock = NSLock()
    static var routes: [String: Behavior] = [:]
    static var requests: [String] = []
    static var stopped = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]; requests = []; stopped = 0
    }
    static func requestCount(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0 == path }.count
    }

    private var isStopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(url.path)
        let behavior = Self.routes[url.path] ?? .status(404)
        Self.lock.unlock()
        DispatchQueue.global().async { [self] in
            switch behavior {
            case .body(let data):
                respond(200, length: data.count)
                send(data)
                client?.urlProtocolDidFinishLoading(self)
            case .status(let code):
                respond(code, length: 0)
                client?.urlProtocolDidFinishLoading(self)
            case .partialThenFail(let data):
                respond(200, length: data.count * 2)
                send(data.prefix(data.count / 2))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .hold:
                respond(200, length: 1_000_000)
                send(Data(repeating: 0, count: 100))
                while !isStopped { Thread.sleep(forTimeInterval: 0.01) }
            case .redirect(let location):
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": location])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            }
        }
    }

    private func respond(_ code: Int, length: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Length": String(length)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    /// 分兩批送，才有機會看到進度變化。
    private func send(_ data: Data) {
        let half = data.count / 2
        client?.urlProtocol(self, didLoad: Data(data.prefix(half)))
        client?.urlProtocol(self, didLoad: Data(data.dropFirst(half)))
    }

    override func stopLoading() {
        isStopped = true
        Self.lock.lock(); Self.stopped += 1; Self.lock.unlock()
    }
}

// MARK: 測試用的假模型（小檔案，真的雜湊）

private struct World {
    let root: URL
    let assets: MeetingDiarizerAssets
    let models: [MeetingDiarizerModel]
    let archive: Data       // 第一個模型：tar.bz2
    let embedding: Data     // 第二個模型：純檔案
    let segmentation: Data  // 壓縮檔裡的模型內容
    var downloader: MeetingDiarizerDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        return MeetingDiarizerDownloader(assets: assets, configuration: configuration)
    }
}

private func makeWorld() throws -> World {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDiarizerDownloaderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // 壓縮檔：pkg/model.onnx
    let segmentation = Data((0..<3000).map { UInt8($0 % 251) })
    let packageDirectory = root.appendingPathComponent("build/pkg", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    try segmentation.write(to: packageDirectory.appendingPathComponent("model.onnx"))
    let archiveURL = root.appendingPathComponent("seg.tar.bz2")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-cjf", archiveURL.path, "-C", root.appendingPathComponent("build").path, "pkg"]
    try tar.run(); tar.waitUntilExit()
    let archive = try Data(contentsOf: archiveURL)
    let embedding = Data((0..<5000).map { UInt8(($0 * 7) % 253) })
    let models = [
        MeetingDiarizerModel(name: "fake-segmentation", url: URL(string: "https://github.com/fake/releases/seg.tar.bz2")!,
                             source: .archive(member: "pkg/model.onnx"),
                             downloadSHA256: sha(archive), downloadBytes: Int64(archive.count),
                             installPath: "pyannote-segmentation/model.onnx",
                             installedSHA256: sha(segmentation), installedBytes: Int64(segmentation.count), licenseNote: nil),
        MeetingDiarizerModel(name: "fake-embedding", url: URL(string: "https://github.com/fake/releases/emb.onnx")!,
                             source: .file,
                             downloadSHA256: sha(embedding), downloadBytes: Int64(embedding.count),
                             installPath: "speaker-embedding.onnx",
                             installedSHA256: sha(embedding), installedBytes: Int64(embedding.count), licenseNote: nil),
    ]
    let assets = MeetingDiarizerAssets(modelsDirectory: root.appendingPathComponent("models"), models: models)
    return World(root: root, assets: assets, models: models, archive: archive, embedding: embedding, segmentation: segmentation)
}

private func serveAll(_ world: World) {
    FakeServer.routes["/fake/releases/seg.tar.bz2"] = .body(world.archive)
    FakeServer.routes["/fake/releases/emb.onnx"] = .body(world.embedding)
}

/// 在測試的主執行緒上等回呼（回呼用 DispatchQueue.main）。
private func run(_ downloader: MeetingDiarizerDownloader, timeout: TimeInterval = 10)
    -> (result: Result<Void, MeetingDiarizerDownloader.Failure>?, progress: [MeetingDiarizerDownloader.Progress], onMain: Bool) {
    var result: Result<Void, MeetingDiarizerDownloader.Failure>?
    var progress: [MeetingDiarizerDownloader.Progress] = []
    var onMain = true
    downloader.start(progress: { onMain = onMain && Thread.isMainThread; progress.append($0) },
                     completion: { onMain = onMain && Thread.isMainThread; result = $0 })
    spin(until: { result != nil }, timeout: timeout)
    return (result, progress, onMain)
}

private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

private func leftovers(_ world: World) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: world.assets.modelsDirectory.path)) ?? []).filter { $0.hasPrefix(".download-") }
}

private func isFailure(_ result: Result<Void, MeetingDiarizerDownloader.Failure>?, _ expected: MeetingDiarizerDownloader.Failure) -> Bool {
    if case .failure(let failure)? = result { return failure == expected }
    return false
}

// MARK: 測試

@main
enum MeetingDiarizerDownloaderTests {
    static func main() throws {
        try testDownloadsVerifiesAndInstallsBothModels()
        try testChecksumMismatchIsRejectedAndNothingIsInstalled()
        try testInterruptedDownloadCanBeRetriedWithoutRedownloadingFinishedModels()
        try testAlreadyInstalledModelsAreNotDownloadedAgain()
        try testHttpErrorsAndInsecureRedirectsAreRejected()
        try testCancelStopsTheRequestAndCleansUp()
        try testBadArchiveAndWrongSizeAreRejected()
        try testExistingWrongSizedFileIsReplacedAtomically()
        print("Meeting diarizer downloader tests passed (8 scenarios, fake HTTP, no real network)")
    }

    static func testDownloadsVerifiesAndInstallsBothModels() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        serveAll(world)
        let outcome = run(world.downloader)
        expect({ if case .success? = outcome.result { return true } else { return false } }(), "download succeeds: \(String(describing: outcome.result))")
        expect(outcome.onMain, "progress and completion are delivered on the main thread")
        expect(world.assets.modelsReady() && world.assets.missingModels().isEmpty, "both models installed")
        expect((try? Data(contentsOf: world.assets.installedURL(for: world.models[0]))) == world.segmentation, "archive member extracted byte for byte")
        expect((try? Data(contentsOf: world.assets.installedURL(for: world.models[1]))) == world.embedding, "file model installed byte for byte")
        expect(leftovers(world).isEmpty, "staging folder removed")
        let fractions = outcome.progress.map(\.fraction)
        expect(!fractions.isEmpty && fractions == fractions.sorted() && fractions.last == 1, "progress is monotonic and ends at 100%: \(fractions)")
        expect(outcome.progress.last?.totalBytes == Int64(world.archive.count + world.embedding.count), "total = sum of the downloads")
    }

    // SHA256 不符（伺服器給了不同的內容）：丟掉，不安裝，不留下暫存檔。
    static func testChecksumMismatchIsRejectedAndNothingIsInstalled() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        var tampered = world.embedding
        tampered[0] ^= 0xFF // 大小相同、內容不同
        FakeServer.routes["/fake/releases/seg.tar.bz2"] = .body(world.archive)
        FakeServer.routes["/fake/releases/emb.onnx"] = .body(tampered)
        let outcome = run(world.downloader)
        expect(isFailure(outcome.result, .checksumMismatch(model: "fake-embedding")), "checksum mismatch is reported: \(String(describing: outcome.result))")
        expect(!FileManager.default.fileExists(atPath: world.assets.installedURL(for: world.models[1]).path), "tampered model was not installed")
        expect(world.assets.isInstalled(world.models[0]) && !world.assets.modelsReady(), "the verified model stays, feature stays unavailable")
        expect(leftovers(world).isEmpty, "no partial files left behind")

        // 大小不對也不能裝。
        FakeServer.routes["/fake/releases/emb.onnx"] = .body(world.embedding + Data([1]))
        let longer = run(world.downloader)
        expect({ if case .failure(.sizeMismatch(let model, _, _))? = longer.result { return model == "fake-embedding" } else { return false } }(),
               "oversized download is rejected: \(String(describing: longer.result))")
        expect(!world.assets.modelsReady() && leftovers(world).isEmpty, "still nothing installed, nothing left")
    }

    // 第二個模型下載到一半斷線 → 失敗；再按一次「重試」只下載缺的那個。
    static func testInterruptedDownloadCanBeRetriedWithoutRedownloadingFinishedModels() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        FakeServer.routes["/fake/releases/seg.tar.bz2"] = .body(world.archive)
        FakeServer.routes["/fake/releases/emb.onnx"] = .partialThenFail(world.embedding)
        let first = run(world.downloader)
        guard case .failure(.network)? = first.result else { expect(false, "expected a network failure: \(String(describing: first.result))"); return }
        expect(world.assets.isInstalled(world.models[0]) && !world.assets.isInstalled(world.models[1]), "first model installed, second not")
        expect(leftovers(world).isEmpty && !world.assets.modelsReady(), "no half-written model")
        expect(FakeServer.requestCount("/fake/releases/seg.tar.bz2") == 1, "first model downloaded once")

        FakeServer.routes["/fake/releases/emb.onnx"] = .body(world.embedding)
        let retry = run(world.downloader)
        expect({ if case .success? = retry.result { return true } else { return false } }(), "retry succeeds: \(String(describing: retry.result))")
        expect(world.assets.modelsReady(), "ready after the retry")
        expect(FakeServer.requestCount("/fake/releases/seg.tar.bz2") == 1, "the finished model was not downloaded again")
        expect(FakeServer.requestCount("/fake/releases/emb.onnx") == 2, "only the missing model was requested again")
        expect(retry.progress.first.map { $0.totalBytes == Int64(world.embedding.count) } == true, "retry progress covers only the missing model")
    }

    static func testAlreadyInstalledModelsAreNotDownloadedAgain() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        serveAll(world)
        expect({ if case .success? = run(world.downloader).result { return true } else { return false } }(), "first install")
        let requestsBefore = FakeServer.requests.count
        FakeServer.reset() // 之後任何請求都會是 404
        let again = run(world.downloader)
        expect({ if case .success? = again.result { return true } else { return false } }(), "second run succeeds immediately")
        expect(FakeServer.requests.isEmpty && requestsBefore == 2, "no network access when everything is already installed")
    }

    static func testHttpErrorsAndInsecureRedirectsAreRejected() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        FakeServer.routes["/fake/releases/seg.tar.bz2"] = .status(503)
        expect(isFailure(run(world.downloader).result, .http(503)), "HTTP 503 is a failure")
        expect(!world.assets.modelsReady() && leftovers(world).isEmpty && !world.assets.isInstalled(world.models[0]), "nothing installed after an HTTP error")

        FakeServer.routes["/fake/releases/seg.tar.bz2"] = .redirect("http://evil.example/seg.tar.bz2")
        let redirected = run(world.downloader)
        expect(isFailure(redirected.result, .insecureRedirect), "redirect to plain http is refused: \(String(describing: redirected.result))")
        FakeServer.lock.lock()
        expect(!FakeServer.requests.contains("/seg.tar.bz2"), "the insecure location was never requested")
        FakeServer.lock.unlock()
    }

    static func testCancelStopsTheRequestAndCleansUp() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        FakeServer.routes["/fake/releases/seg.tar.bz2"] = .hold
        let downloader = world.downloader
        var result: Result<Void, MeetingDiarizerDownloader.Failure>?
        downloader.start(progress: { _ in }, completion: { result = $0 })
        spin(until: { FakeServer.requestCount("/fake/releases/seg.tar.bz2") == 1 })
        downloader.cancel()
        spin(until: { result != nil })
        expect(isFailure(result, .cancelled), "cancel reports .cancelled: \(String(describing: result))")
        FakeServer.lock.lock(); let stopped = FakeServer.stopped; FakeServer.lock.unlock()
        expect(stopped >= 1, "the request was stopped")
        expect(leftovers(world).isEmpty && !world.assets.modelsReady(), "cancel leaves nothing behind")
        // 取消之後可以再開始。
        serveAll(world)
        expect({ if case .success? = run(world.downloader).result { return true } else { return false } }(), "download works after a cancel")
    }

    static func testBadArchiveAndWrongSizeAreRejected() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        // 雜湊正確但壓縮檔裡沒有預期的成員。
        let wrongMember = MeetingDiarizerModel(
            name: "fake-segmentation", url: world.models[0].url, source: .archive(member: "pkg/missing.onnx"),
            downloadSHA256: world.models[0].downloadSHA256, downloadBytes: world.models[0].downloadBytes,
            installPath: world.models[0].installPath, installedSHA256: world.models[0].installedSHA256,
            installedBytes: world.models[0].installedBytes, licenseNote: nil)
        let assets = MeetingDiarizerAssets(modelsDirectory: world.assets.modelsDirectory, models: [wrongMember, world.models[1]])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        serveAll(world)
        let outcome = run(MeetingDiarizerDownloader(assets: assets, configuration: configuration))
        guard case .failure(.badArchive(let model, _))? = outcome.result else { expect(false, "expected badArchive: \(String(describing: outcome.result))"); return }
        expect(model == "fake-segmentation", "names the model")
        expect(!assets.isInstalled(wrongMember) && leftovers(world).isEmpty, "nothing installed")

        // 模型內容雜湊不符（壓縮檔本身雜湊正確）。
        let wrongHash = MeetingDiarizerModel(
            name: "fake-segmentation", url: world.models[0].url, source: world.models[0].source,
            downloadSHA256: world.models[0].downloadSHA256, downloadBytes: world.models[0].downloadBytes,
            installPath: world.models[0].installPath, installedSHA256: String(repeating: "0", count: 64),
            installedBytes: world.models[0].installedBytes, licenseNote: nil)
        let hashAssets = MeetingDiarizerAssets(modelsDirectory: world.assets.modelsDirectory, models: [wrongHash])
        let hashOutcome = run(MeetingDiarizerDownloader(assets: hashAssets, configuration: configuration))
        expect(isFailure(hashOutcome.result, .checksumMismatch(model: "fake-segmentation")), "extracted model hash is verified too: \(String(describing: hashOutcome.result))")
        expect(!hashAssets.isInstalled(wrongHash), "not installed")
    }

    // 目的地已經有一個大小不對的舊檔：驗證通過後原子替換。
    static func testExistingWrongSizedFileIsReplacedAtomically() throws {
        FakeServer.reset()
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        serveAll(world)
        let destination = world.assets.installedURL(for: world.models[1])
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: destination)
        expect(!world.assets.isInstalled(world.models[1]), "the old file is not a valid install")
        let outcome = run(world.downloader)
        expect({ if case .success? = outcome.result { return true } else { return false } }(), "download succeeds")
        expect((try? Data(contentsOf: destination)) == world.embedding, "the broken file was replaced by the verified one")
        expect(leftovers(world).isEmpty, "staging removed")

        // 失敗的下載不能破壞「已經裝好的」模型。
        FakeServer.routes["/fake/releases/emb.onnx"] = .status(500)
        try FileManager.default.removeItem(at: destination)
        try Data("truncated".utf8).write(to: destination)
        let failed = run(world.downloader)
        expect(isFailure(failed.result, .http(500)), "failed replacement")
        expect((try? Data(contentsOf: destination)) == Data("truncated".utf8), "an existing file is only replaced after the new one is verified")
    }
}
