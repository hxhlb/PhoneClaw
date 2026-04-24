import Foundation

actor ResumableAssetDownloader {
    private let manifestStore: DownloadManifestStore
    private let observer: any DownloadObserver

    init(
        manifestStore: DownloadManifestStore,
        observer: any DownloadObserver = NoopDownloadObserver()
    ) {
        self.manifestStore = manifestStore
        self.observer = observer
    }

    func download(asset: DownloadAsset) async throws -> DownloadProgressSnapshot {
        fatalError("Phase 2")
    }

    func pause(assetID: String) async {
        fatalError("Phase 2")
    }

    func purge(assetID: String) async throws {
        fatalError("Phase 2")
    }

    func pruneOrphans(knownAssetIDs: Set<String>) async throws {
        fatalError("Phase 4")
    }
}
