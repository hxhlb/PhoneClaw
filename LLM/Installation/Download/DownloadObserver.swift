import Foundation

protocol DownloadObserver: Sendable {
    func onProgress(_ snapshot: DownloadProgressSnapshot)
    func onRetry(
        assetID: String,
        filePath: String,
        source: DownloadFile.Source,
        attempt: Int,
        error: DownloadFailure
    )
    func onSourceSwitch(
        assetID: String,
        filePath: String,
        from: DownloadFile.Source?,
        to: DownloadFile.Source,
        reason: DownloadFailure?
    )
    func onFailure(assetID: String, failure: DownloadFailure)
}

extension DownloadObserver {
    func onProgress(_ snapshot: DownloadProgressSnapshot) {}

    func onRetry(
        assetID: String,
        filePath: String,
        source: DownloadFile.Source,
        attempt: Int,
        error: DownloadFailure
    ) {}

    func onSourceSwitch(
        assetID: String,
        filePath: String,
        from: DownloadFile.Source?,
        to: DownloadFile.Source,
        reason: DownloadFailure?
    ) {}

    func onFailure(assetID: String, failure: DownloadFailure) {}
}

struct NoopDownloadObserver: DownloadObserver {}
