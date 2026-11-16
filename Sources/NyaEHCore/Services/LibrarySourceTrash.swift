import Foundation

protocol LibrarySourceTrashing: Sendable {
    func identity(at url: URL) throws -> String?
    func trash(_ url: URL) throws
}

struct LibrarySourceTrash: LibrarySourceTrashing {
    func identity(at url: URL) throws -> String? {
        try TestRuntime.validateSourceFile(url)
        do {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular else { throw LibraryDeletionError.sourceChanged }
            return "\(values[.systemNumber] ?? ""):\(values[.systemFileNumber] ?? ""):\(values[.size] ?? ""):\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
            if error.domain == NSPOSIXErrorDomain && error.code == ENOENT { return nil }
            throw error
        }
    }
    func trash(_ url: URL) throws {
        try TestRuntime.validateSourceFile(url)
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        if let result { try TestRuntime.recordTrash(source: url, target: result as URL) }
    }
}
