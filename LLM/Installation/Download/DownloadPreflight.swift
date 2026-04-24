import Foundation

enum DownloadPreflight: Sendable {
    static func availableCapacity(for directory: URL) throws -> Int64? {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage
    }

    static func validateDiskSpace(requiredBytes: Int64, at directory: URL) throws {
        guard let available = try availableCapacity(for: directory) else { return }
        guard available >= requiredBytes else {
            throw DownloadFailure.insufficientDiskSpace(required: requiredBytes, available: available)
        }
    }
}
