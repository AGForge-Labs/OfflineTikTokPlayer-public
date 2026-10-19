import Foundation
import Observation
import PlayerCore

@MainActor @Observable
final class OfflineDownloads: NSObject {
    static let sessionIdentifier = "dev.galaxybigbird.OfflineTikTokPlayer.downloads"
    private(set) var records: [String: DownloadRecord] = [:]
    private(set) var readyIDs = Set<String>()
    private(set) var orderedIDs: [String] = []
    private(set) var usedBytes: Int64 = 0
    private(set) var message: String?
    var wifiOnly: Bool {
        didSet {
            guard wifiOnly != oldValue else { return }
            UserDefaults.standard.set(wifiOnly, forKey: "wifiOnlyDownloads")
            applyNetworkPolicy()
            pump()
        }
    }
    let network: NetworkStatus
    @ObservationIgnored private let cloud: OneDriveClient
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var resolutionJobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retries = Set<String>()
    @ObservationIgnored private var verified = Set<String>()
    @ObservationIgnored private var lastProgress: [String: Date] = [:]
    @ObservationIgnored private var policyRestarts = Set<String>()
    @ObservationIgnored private var backgroundGate = BackgroundTransferGate()
    @ObservationIgnored var backgroundCompletion: (() -> Void)? { didSet { finishBackgroundEvents() } }
    nonisolated private let staging = AppFiles.directory("Staging", excludeFromBackup: true)
    private let files = AppFiles.directory("Offline", excludeFromBackup: true)
    private let transfers = AppFiles.directory("Transfers", excludeFromBackup: true)
    private let ledgerURL = AppFiles.root.appendingPathComponent("downloads.json")
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(cloud: OneDriveClient, network: NetworkStatus) {
        self.cloud = cloud; self.network = network
        wifiOnly = UserDefaults.standard.object(forKey: "wifiOnlyDownloads") as? Bool ?? true
        super.init()
        do {
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                records = try JSONDecoder().decode([String: DownloadRecord].self, from: Data(contentsOf: ledgerURL))
                for (id, record) in records { try record.asset.validate(); if record.mediaID != id { throw AppError.message("Invalid download checkpoint.") } }
            }
        } catch { records = [:]; message = "Download checkpoints could not be read. Your cloud files are unchanged." }
        updateSummary()
        network.didChange = { [weak self] in self?.pump() }
        session.getAllTasks { [weak self] existing in
            Task { @MainActor in
                guard let self else { return }
                for task in existing {
                    guard let id = task.taskDescription, self.records[id] != nil,
                          let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
                    self.tasks[id] = download
                }
                for id in Array(self.records.keys) {
                    self.records[id]?.prepareForRelaunch(hasBackgroundTask: self.tasks[id] != nil)
                    if self.records[id]?.isReady == true, !FileManager.default.fileExists(atPath: self.fileURL(self.records[id]!.asset).path) {
                        self.records[id]?.state = .failed; self.records[id]?.error = "Offline copy is missing. Download it again."
                    }
                }
                self.applyNetworkPolicy(); self.persist(); self.pump()
            }
        }
    }

    private func updateSummary() {
        let completed = records.values.filter(\.isReady)
        readyIDs = Set(completed.map(\.mediaID))
        let sorted = records.keys.sorted(by: >)
        if sorted != orderedIDs { orderedIDs = sorted }
        var hashes = Set<String>()
        usedBytes = completed.reduce(0) { $0 + (hashes.insert($1.asset.sha256).inserted ? $1.asset.byteSize : 0) }
    }
    private func fileURL(_ asset: AssetReference) -> URL { files.appendingPathComponent(asset.sha256 + ".mp4") }
    private func resumeURL(_ asset: AssetReference) -> URL { transfers.appendingPathComponent(asset.sha256 + ".resume") }
    private func persist() {
        updateSummary()
        do { try AppFiles.save(records, to: ledgerURL) }
        catch { message = "Could not save download progress: \(error.localizedDescription)" }
    }

    func enqueue(_ media: [MediaRecord]) {
        let assets = media.compactMap(\.asset)
        let needed = DownloadRecord.estimatedBytes(assets, verifiedHashes: Set(records.values.filter(\.isReady).map(\.asset.sha256)))
        let capacity = (try? files.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity > needed + 100_000_000 else { message = "Not enough iPhone storage. These videos need about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))."; return }
        for item in media {
            guard let asset = item.asset, item.status == .ready else { continue }
            if records[item.id]?.isReady == true, records[item.id]?.asset.sha256 == asset.sha256 { continue }
            if let record = records[item.id], record.asset == asset, [.downloading, .resolving].contains(record.state) { continue }
            records[item.id] = DownloadRecord(mediaID: item.id, asset: asset)
            retries.remove(item.id)
        }
        message = nil; persist(); pump()
    }

    func resume(_ id: String) {
        guard records[id] != nil, records[id]?.isReady == false else { return }
        records[id]?.state = .queued; records[id]?.error = nil; retries.remove(id)
        persist(); pump()
    }

    func pause(_ id: String) {
        guard var record = records[id], !record.isReady else { return }
        record.state = .paused; records[id] = record
        policyRestarts.remove(id)
        // Keep the slot until its task exits; an immediate Resume must not overlap it.
        resolutionJobs[id]?.cancel()
        let originalWiFiOnly = tasks[id]?.originalRequest?.allowsCellularAccess == false
        tasks[id]?.cancel { [weak self] data in
            Task { @MainActor in
                guard let self, let data, self.records[id]?.state == .paused else { return }
                try? AppFiles.save(ResumeCheckpoint(data: data, wifiOnly: originalWiFiOnly), to: self.resumeURL(record.asset))
            }
        }
        persist()
    }

    func remove(_ id: String) {
        guard let record = records[id] else { return }
        pause(id); records.removeValue(forKey: id); verified.remove(record.asset.sha256)
        try? FileManager.default.removeItem(at: resumeURL(record.asset))
        if !records.values.contains(where: { $0.asset.sha256 == record.asset.sha256 && $0.isReady }) {
            try? FileManager.default.removeItem(at: fileURL(record.asset))
        }
        persist()
    }

    func localURL(for item: MediaRecord) async -> URL? {
        guard let record = records[item.id], record.isReady,
              item.asset == nil || item.asset?.sha256 == record.asset.sha256 else { return nil }
        let url = fileURL(record.asset)
        if verified.contains(record.asset.sha256), FileManager.default.fileExists(atPath: url.path) { return url }
        let expected = record.asset
        let valid = await Task.detached(priority: .userInitiated) {
            guard let result = try? AppFiles.hash(url) else { return false }
            return result.size == expected.byteSize && result.sha256 == expected.sha256
        }.value
        guard valid else { records[item.id]?.state = .failed; records[item.id]?.error = "Offline copy failed verification. Download it again."; persist(); return nil }
        verified.insert(expected.sha256)
        return url
    }

    func importLocal(_ source: URL, mediaID: String? = nil) async throws -> (String, AssetReference) {
        let destinationRoot = files
        let result = try await Task.detached(priority: .userInitiated) {
            let digest = try AppFiles.hash(source)
            guard digest.size > 0 else { throw AppError.message("This video file is empty.") }
            let destination = destinationRoot.appendingPathComponent(digest.sha256 + ".mp4")
            if !FileManager.default.fileExists(atPath: destination.path) {
                let temporary = destinationRoot.appendingPathComponent(UUID().uuidString + ".part")
                try FileManager.default.copyItem(at: source, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return digest
        }.value
        let id = mediaID ?? "local:" + result.sha256
        let asset = AssetReference(driveID: "local", itemID: result.sha256, fileName: "local.mp4", byteSize: result.size, sha256: result.sha256, contentType: "video/mp4")
        var record = DownloadRecord(mediaID: id, asset: asset)
        try record.finish(byteSize: result.size, sha256: result.sha256)
        records[id] = record; verified.insert(result.sha256); persist()
        return (id, asset)
    }

    private func pump() {
        guard TransferNetworkPolicy(wifiOnly: wifiOnly).canSchedule(isConnected: network.isConnected, isWiFi: network.isWiFi) else { return }
        var busyHashes = Set(tasks.keys.compactMap { records[$0]?.asset.sha256 })
        busyHashes.formUnion(resolutionJobs.keys.compactMap { records[$0]?.asset.sha256 })
        for record in records.values.filter({ $0.state == .queued }) {
            guard tasks.count + resolutionJobs.count < 2 else { break }
            guard !busyHashes.contains(record.asset.sha256) else { continue }
            if let ready = records.values.first(where: { $0.isReady && $0.asset.sha256 == record.asset.sha256 }) {
                var copy = record; try? copy.finish(byteSize: ready.asset.byteSize, sha256: ready.asset.sha256); records[record.mediaID] = copy
                continue
            }
            busyHashes.insert(record.asset.sha256)
            records[record.mediaID]?.state = .resolving
            backgroundGate.beginScheduling(record.mediaID)
            resolutionJobs[record.mediaID] = Task { [weak self] in await self?.start(record) }
        }
        persist()
    }

    private func start(_ record: DownloadRecord) async {
        let id = record.mediaID
        defer {
            resolutionJobs.removeValue(forKey: id)
            backgroundGate.endScheduling(id)
            pump(); finishBackgroundEvents()
        }
        do {
            let url = try await cloud.downloadURL(record.asset, forceRefresh: retries.contains(id))
            try Task.checkCancellation()
            guard records[id]?.state == .resolving else { return }
            let policy = TransferNetworkPolicy(wifiOnly: wifiOnly)
            guard policy.canSchedule(isConnected: network.isConnected, isWiFi: network.isWiFi) else {
                records[id]?.state = .queued; persist(); return
            }
            var request = URLRequest(url: url)
            request.allowsCellularAccess = !wifiOnly
            request.allowsExpensiveNetworkAccess = !wifiOnly
            request.timeoutInterval = 60
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: resumeURL(record.asset)),
               let checkpoint = try? JSONDecoder().decode(ResumeCheckpoint.self, from: data), policy.canReuseResumeData(savedWiFiOnly: checkpoint.wifiOnly) {
                task = session.downloadTask(withResumeData: checkpoint.data)
            }
            else { task = session.downloadTask(with: request) }
            task.taskDescription = id; tasks[id] = task
            records[id]?.state = .downloading; task.resume(); persist()
        } catch is CancellationError { /* The user paused this job. */ }
        catch {
            guard !Task.isCancelled else { return }
            if records[id]?.state != .paused { records[id]?.state = .failed; records[id]?.error = "Could not start download. Connect your account and retry." }
            persist()
        }
    }

    private func received(id: String, taskID: Int, status: Int, url: URL) async {
        defer {
            try? FileManager.default.removeItem(at: url)
            backgroundGate.endVerification(String(taskID)); finishBackgroundEvents()
        }
        guard let record = records[id], tasks[id]?.taskIdentifier == taskID else { return }
        tasks.removeValue(forKey: id)
        policyRestarts.remove(id)
        if [401, 403].contains(status), retries.insert(id).inserted {
            try? FileManager.default.removeItem(at: resumeURL(record.asset))
            records[id]?.state = .queued; persist(); pump(); return
        }
        guard [200, 206].contains(status) else { records[id]?.state = .failed; records[id]?.error = "Download failed (\(status)). Retry when connected."; persist(); pump(); return }
        records[id]?.state = .verifying; persist()
        let result = await Task.detached(priority: .utility) { Result { try AppFiles.hash(url) } }.value
        do {
            let digest = try result.get()
            var completed = record
            try completed.finish(byteSize: digest.size, sha256: digest.sha256)
            guard records[id] != nil else { return }
            let destination = fileURL(record.asset)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: url, to: destination)
            for key in Array(records.keys) where records[key]?.asset.sha256 == record.asset.sha256 {
                try records[key]?.finish(byteSize: digest.size, sha256: digest.sha256)
            }
            verified.insert(record.asset.sha256)
            try? FileManager.default.removeItem(at: resumeURL(record.asset))
        } catch { records[id]?.state = .failed; records[id]?.error = "Download failed verification. Retry to replace this copy." }
        persist(); pump()
    }

    private func failed(id: String, taskID: Int, error: Error?) {
        guard let error else { return } // Success is finalized by didFinishDownloadingTo, after verification.
        guard tasks[id]?.taskIdentifier == taskID else { return }
        let policyWiFiOnly = tasks[id]?.originalRequest?.allowsCellularAccess == false
        tasks.removeValue(forKey: id)
        guard let record = records[id] else { pump(); return }
        if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? AppFiles.save(ResumeCheckpoint(data: resume, wifiOnly: policyWiFiOnly), to: resumeURL(record.asset))
        } else { try? FileManager.default.removeItem(at: resumeURL(record.asset)) }
        if policyRestarts.remove(id) != nil {
            records[id]?.state = .queued; records[id]?.error = nil
        } else if records[id]?.state != .paused {
            records[id]?.state = .failed; records[id]?.error = "Transfer interrupted. Tap Resume to continue."
        }
        persist(); pump()
    }

    private func finishBackgroundEvents() {
        guard backgroundCompletion != nil, backgroundGate.takeCompletionPermission() else { return }
        let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
    }

    private func applyNetworkPolicy() {
        let policy = TransferNetworkPolicy(wifiOnly: wifiOnly)
        for (id, task) in tasks where records[id]?.state != .paused {
            guard policy.needsRestart(taskAllowsCellular: task.originalRequest?.allowsCellularAccess ?? !wifiOnly) else { continue }
            // URLSession request policies are immutable, including the request inside resume data.
            // Cancel and enqueue with the new policy even if the phone is currently using Wi-Fi.
            policyRestarts.insert(id); records[id]?.state = .queued
            task.cancel()
        }
    }

    private struct ResumeCheckpoint: Codable { let data: Data; let wifiOnly: Bool }
}

extension OfflineDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let stable = staging.appendingPathComponent(UUID().uuidString + ".download")
        do { try FileManager.default.moveItem(at: location, to: stable) }
        catch {
            MainActor.assumeIsolated {
                self.tasks.removeValue(forKey: id); self.records[id]?.state = .failed
                self.records[id]?.error = "Could not retain the downloaded file."; self.persist(); self.pump()
            }
            return
        }
        let taskID = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            self.backgroundGate.beginVerification(String(taskID))
            Task { await self.received(id: id, taskID: taskID, status: status, url: stable) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        MainActor.assumeIsolated { self.failed(id: id, taskID: task.taskIdentifier, error: error) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                               totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            guard self.records[id] != nil, Date().timeIntervalSince(self.lastProgress[id] ?? .distantPast) > 0.25 else { return }
            self.lastProgress[id] = Date(); self.records[id]?.receivedBytes = totalBytesWritten
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { self.backgroundGate.eventsDelivered(); self.finishBackgroundEvents() }
    }
}
