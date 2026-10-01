// Lists or records ONE process's windows and nothing else, for pictures that get
// published. Built on demand by scripts/capture-screenshots.sh and
// scripts/capture-demo-gif.sh into .build/own-windows.
//
//   own-windows screen
//       the main display's size in points, "w h"
//   own-windows windows PID
//       its on-screen windows, one per line: "id layer x y w h", in global points
//       from the top-left of the main display (the space `screencapture -R` and
//       CGEvent use)
//   own-windows record PID SECONDS DIR X Y W H
//       records the rect (same space) for SECONDS into DIR/f-<ms>.png, at Retina
//       scale, with every other app left out and a flat backdrop behind
//
//   OWN_WINDOWS_BG="r g b"   the backdrop, 0–255 (default 44 47 56, a neutral slate)
//   OWN_WINDOWS_FPS=60       the most frames a second it delivers
//
// Why ScreenCaptureKit and not `screencapture -R`: a rectangle cut from the whole
// screen carries whatever is there — the menu bar's other items, a window behind the
// floating cat — and these files go into the README. Filtered to one application,
// nothing else can reach a frame. The process's status-bar item is left out too
// (the status-window level, 25; the island sits above it, so it is matched exactly):
// the island's rectangle can reach it on a narrow screen.
//
// ScreenCaptureKit delivers a frame only when something on screen changed, so frames
// are not evenly spaced; each file is named by the milliseconds since the recording
// started, and a video is assembled from those times, not from a frame rate.
import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("own-windows: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func number(_ index: Int) -> Double {
    guard index < args.count, let value = Double(args[index]) else { fail("missing or bad number at argument \(index + 1)") }
    return value
}

if args.first == "screen" {
    let size = CGDisplayBounds(CGMainDisplayID()).size
    print(String(format: "%.0f %.0f", size.width, size.height))
    exit(0)
}

guard args.count >= 2, let pid = pid_t(args[1]) else {
    fail("usage: own-windows screen | windows PID | record PID SECONDS DIR X Y W H")
}

switch args[0] {
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
        guard let id = info[kCGWindowNumber as String] as? Int,
              let layer = info[kCGWindowLayer as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
        print(String(format: "%d %d %.0f %.0f %.0f %.0f", id, layer, rect.minX, rect.minY, rect.width, rect.height))
    }

case "record":
    let seconds = number(2)
    guard args.count >= 8 else { fail("record needs PID SECONDS DIR X Y W H") }
    let dir = args[3]
    let rect = CGRect(x: number(4), y: number(5), width: number(6), height: number(7))
    let env = ProcessInfo.processInfo.environment
    let rgb = (env["OWN_WINDOWS_BG"] ?? "44 47 56").split(separator: " ").compactMap { Double($0) }
    guard rgb.count == 3 else { fail("OWN_WINDOWS_BG must be three numbers, \"r g b\"") }
    let fps = Int32(env["OWN_WINDOWS_FPS"] ?? "60") ?? 60
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    final class Frames: NSObject, SCStreamOutput {
        let dir: String
        let start = Date()
        let context = CIContext()
        var count = 0
        init(dir: String) { self.dir = dir }
        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, buffer.isValid, let pixels = buffer.imageBuffer else { return }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let image = CIImage(cvPixelBuffer: pixels)
            guard let cg = context.createCGImage(image, from: image.extent) else { return }
            let url = URL(fileURLWithPath: dir + String(format: "/f-%06d.png", ms)) as CFURL
            guard let file = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(file, cg, nil)
            if CGImageDestinationFinalize(file) { count += 1 }
        }
    }

    _ = NSApplication.shared
    let frames = Frames(dir: dir)
    // Held here, not created in the assignment: the configuration keeps the colour
    // `unowned(unsafe)`, so a temporary would be freed before the stream reads it.
    let backdrop = CGColor(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1)
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                fail("no main display")
            }
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                fail("process \(pid) has no windows to record")
            }
            let statusItems = content.windows.filter { $0.owningApplication?.processID == pid
                && $0.windowLayer == Int(CGWindowLevelForKey(.statusWindow)) }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: statusItems)
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(rect.width * 2)
            config.height = Int(rect.height * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
            config.showsCursor = false
            config.backgroundColor = backdrop
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(seconds))
            try await stream.stopCapture()
            print("frames \(frames.count)")
            exit(frames.count > 0 ? 0 : 1)
        } catch {
            fail("\(error)")
        }
    }
    dispatchMain()

default:
    fail("unknown command '\(args[0])'")
}
