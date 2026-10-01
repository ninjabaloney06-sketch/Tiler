import Foundation

/// Command-line flags of the executable (SPEC §5):
///
///     Tiler [--config <path>] [--show-settings]
///     Tiler --render-palette <out.png> [--dark] [--size <s>] [--highlight <n>] [--header <text>]
///                            [--no-target] [--revert] [--config <path>]
///     Tiler --render-editor <out.png> [--dark] [--config <path>]
///
/// `--config` points the ConfigStore at another file (tests and critics never touch the real
/// config). `--show-settings` opens the settings window at launch (a directly launched binary
/// cannot be reopened with `open`). The render flags draw a PNG at 2× without showing anything
/// and exit.
/// `--highlight <n>` draws the n-th palette preset (row-major, 0-based) with the hover
/// selection look, for side-by-side checks against the native menu captures. `--header` sets the
/// palette's target line, `--no-target` renders the "No window" state (single-window presets
/// dimmed), `--revert` shows the Revert tile.
struct LaunchOptions {
    enum Mode: Equatable {
        case run
        case renderPalette(URL)
        case renderEditor(URL)
    }

    var mode = Mode.run
    var configURL: URL?
    /// `--show-settings`: open the settings window at launch (run mode).
    var showSettings = false
    var dark = false
    /// `--size`: palette size for `--render-palette` (default: the configured size).
    var size: Double?
    /// `--highlight`: palette preset shown selected in `--render-palette`.
    var highlight: Int?
    /// `--header`, `--no-target`, `--revert`: the target state `--render-palette` shows.
    var header: String?
    var noTarget = false
    var revert = false

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    static let usage = """
        usage: Tiler [--config <path>] [--show-settings]
               Tiler --render-palette <out.png> [--dark] [--size <s>] [--highlight <n>] [--header <text>]
                                      [--no-target] [--revert] [--config <path>]
               Tiler --render-editor <out.png> [--dark] [--config <path>]
        """

    /// Parses the arguments after the executable path. Unknown `--` flags are errors; other
    /// arguments (e.g. Cocoa's `-Key value` defaults) are ignored.
    static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var rest = arguments[...]

        func value(for flag: String) throws -> String {
            guard let value = rest.popFirst(), !value.hasPrefix("--") else {
                throw UsageError(description: "\(flag) needs a value")
            }
            return value
        }
        func fileURL(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        func setMode(_ mode: Mode) throws {
            guard options.mode == .run else {
                throw UsageError(description: "use only one of --render-palette and --render-editor")
            }
            options.mode = mode
        }

        while let argument = rest.popFirst() {
            switch argument {
            case "--config":
                options.configURL = fileURL(try value(for: argument))
            case "--render-palette":
                try setMode(.renderPalette(fileURL(try value(for: argument))))
            case "--render-editor":
                try setMode(.renderEditor(fileURL(try value(for: argument))))
            case "--show-settings":
                options.showSettings = true
            case "--dark":
                options.dark = true
            case "--size":
                let text = try value(for: argument)
                guard let size = Double(text), size > 0 else {
                    throw UsageError(description: "--size needs a positive number, got \(text)")
                }
                options.size = size
            case "--highlight":
                let text = try value(for: argument)
                guard let index = Int(text), index >= 0 else {
                    throw UsageError(description: "--highlight needs a preset index ≥ 0, got \(text)")
                }
                options.highlight = index
            case "--header":
                options.header = try value(for: argument)
            case "--no-target":
                options.noTarget = true
            case "--revert":
                options.revert = true
            case let flag where flag.hasPrefix("--"):
                throw UsageError(description: "unknown option \(flag)")
            default:
                continue
            }
        }
        return options
    }
}
