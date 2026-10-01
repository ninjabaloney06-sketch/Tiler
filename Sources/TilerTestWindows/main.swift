import AppKit

// TilerTestWindows — live-test helper for the window engine (SPEC §7, C2).
//
//   TilerTestWindows <n> [--min-size <k>:<W>x<H>] [--fixed-size <k>] [--control] [--light]
//
// Opens n titled, resizable, standard, full-screen-capable windows "TW1"…"TWn" at distinct
// cascaded positions (TW1 frontmost), activates itself, prints "PID <pid>" on stdout and stays
// alive until killed.
//   --min-size k:WxH  window k gets a minimum frame size of W×H pt (the engine must re-align it).
//   --fixed-size k    window k is not resizable (360×240 pt, not full-screen capable): the engine
//                     can only move it.
//   --control         read commands from stdin, one per line, and exit at EOF (so the helper dies
//                     with the harness that owns the pipe):
//                       show <m>  windows 1…m visible, the rest ordered out; replies "OK show <m>".
//                       sheet on  attaches a sheet to TW1 (it takes focus); replies "OK sheet on".
//                       sheet off ends TW1's sheet; replies "OK sheet off".
//   --light           forces the light (aqua) appearance whatever the system setting
//                     (`tiler-hovertest --hat-alpha-sweep` measures the hat on a light titlebar).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("TilerTestWindows: \(message)\n".utf8))
    FileHandle.standardError.write(Data(
        "usage: TilerTestWindows <n> [--min-size <k>:<W>x<H>] [--fixed-size <k>] [--control] [--light]\n".utf8))
    exit(2)
}

func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, let count = Int(first), (1...64).contains(count) else {
    fail("first argument must be the window count (1…64)")
}
arguments.removeFirst()

var minSizes: [Int: NSSize] = [:]
var fixedSize: Set<Int> = []
var control = false
var light = false
while !arguments.isEmpty {
    let option = arguments.removeFirst()
    switch option {
    case "--min-size":
        guard !arguments.isEmpty else { fail("--min-size needs <k>:<W>x<H>") }
        let parts = arguments.removeFirst().split(separator: ":")
        let dims = parts.count == 2 ? parts[1].split(separator: "x") : []
        guard parts.count == 2, let k = Int(parts[0]), (1...count).contains(k), dims.count == 2,
              let w = Double(dims[0]), let h = Double(dims[1]), w > 0, h > 0
        else { fail("bad --min-size value") }
        minSizes[k] = NSSize(width: w, height: h)
    case "--fixed-size":
        guard !arguments.isEmpty, let k = Int(arguments.removeFirst()), (1...count).contains(k) else {
            fail("--fixed-size needs a window number 1…\(count)")
        }
        fixedSize.insert(k)
    case "--control":
        control = true
    case "--light":
        light = true
    default:
        fail("unknown option \(option)")
    }
}

// MARK: Windows

let app = NSApplication.shared
app.setActivationPolicy(.regular)
if light { app.appearance = NSAppearance(named: .aqua) }

let defaultSize = NSSize(width: 400, height: 300)
let fixedWindowSize = NSSize(width: 360, height: 240)
let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 956

var windows: [NSWindow] = []
for index in 1...count {
    let isFixed = fixedSize.contains(index)
    var size = isFixed ? fixedWindowSize : defaultSize
    if let minimum = minSizes[index] {
        size = NSSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
    }
    // Cascade in AX space (top-left origin): 28 pt right and 22 pt down per window, clear of the
    // Stage Manager strip on the left.
    let axOrigin = CGPoint(x: 200 + 28 * CGFloat(index - 1), y: 80 + 22 * CGFloat(index - 1))
    let rect = NSRect(x: axOrigin.x, y: primaryMaxY - axOrigin.y - size.height, width: size.width, height: size.height)
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
    if !isFixed { style.insert(.resizable) }
    let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "TW\(index)"
    window.collectionBehavior = isFixed ? [.fullScreenNone] : [.fullScreenPrimary]
    if let minimum = minSizes[index] { window.minSize = minimum }
    window.setFrame(rect, display: false)
    let label = NSTextField(labelWithString: "Tiler test window TW\(index)")
    label.frame = NSRect(x: 12, y: 12, width: 260, height: 20)
    window.contentView?.addSubview(label)
    windows.append(window)
}

app.activate()
for window in windows.reversed() {
    window.makeKeyAndOrderFront(nil)
}
say("PID \(ProcessInfo.processInfo.processIdentifier)")

// MARK: Control channel

enum Control {
    static func handle(_ line: String) {
        let words = line.split(separator: " ")
        if words.count == 2, words[0] == "show", let visible = Int(words[1]), (0...windows.count).contains(visible) {
            for (index, window) in windows.enumerated() {
                if index < visible {
                    if !window.isVisible { window.orderFront(nil) }
                } else {
                    window.orderOut(nil)
                }
            }
            say("OK show \(visible)")
        } else if line == "sheet on" {
            if windows[0].attachedSheet == nil {
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                                     styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                windows[0].beginSheet(sheet)
            }
            say("OK sheet on")
        } else if line == "sheet off" {
            if let sheet = windows[0].attachedSheet { windows[0].endSheet(sheet) }
            say("OK sheet off")
        } else {
            say("ERR \(line)")
        }
    }
}

if control {
    Thread.detachNewThread {
        while let line = readLine() {
            Task { @MainActor in Control.handle(line) }
        }
        exit(0)
    }
}

app.run()
