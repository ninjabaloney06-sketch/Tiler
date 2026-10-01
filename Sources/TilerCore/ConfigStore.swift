import Foundation
import Observation

extension Notification.Name {
    /// Posted by `ConfigStore` after every change of `config`; `object` is the store. Delivered
    /// synchronously on the thread that made the change (the main thread in the app).
    public static let tilerConfigDidChange = Notification.Name("TilerConfigDidChange")
}

/// Owns the persisted `TilerConfig` (SPEC §2, §7).
///
/// - Loads once at init. A missing, unreadable, corrupt or wrong-version file yields
///   `TilerConfig.default` and never crashes; the file is left untouched until the next change.
/// - Every change of `config` is written immediately (JSON, atomic replace, parent directory
///   created on demand) and announced twice: through Observation (`@Observable`, for SwiftUI
///   bindings like `$store.config.settings.gap`) and as `.tilerConfigDidChange`.
/// - Not thread-safe and not actor-isolated: use one store from one isolation domain (the app
///   keeps it on the main actor). The file path is injectable for tests.
@Observable
public final class ConfigStore {
    public enum LoadResult: Hashable, Sendable {
        /// The file was read and decoded.
        case loaded
        /// No file at `fileURL`; defaults are in use.
        case missing
        /// The file could not be read or decoded; defaults are in use.
        case invalid(reason: String)
    }

    /// `~/Library/Application Support/Tiler/config.json`.
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Tiler/config.json", directoryHint: .notDirectory)
    }

    @ObservationIgnored public let fileURL: URL
    /// How the initial load went (for logging and tests).
    @ObservationIgnored public private(set) var loadResult: LoadResult
    /// Description of the most recent failed write, nil after a successful one.
    public private(set) var lastSaveError: String?

    /// The current configuration. Assigning a different value saves and notifies.
    public var config: TilerConfig {
        didSet {
            guard config != oldValue else { return }
            do {
                try write()
                lastSaveError = nil
            } catch {
                lastSaveError = String(describing: error)
            }
            NotificationCenter.default.post(name: .tilerConfigDidChange, object: self)
        }
    }

    public init(fileURL: URL = ConfigStore.defaultFileURL) {
        self.fileURL = fileURL
        (config, loadResult) = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> (TilerConfig, LoadResult) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (.default, .missing)
        } catch {
            return (.default, .invalid(reason: String(describing: error)))
        }
        do {
            return (try JSONDecoder().decode(TilerConfig.self, from: data), .loaded)
        } catch {
            return (.default, .invalid(reason: String(describing: error)))
        }
    }

    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
