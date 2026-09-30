// A tiny CGEvent driver for checking the island without hands: hover, click, keys.
// Built on demand by scripts/dev/island-shot.sh into .build/cgev.
//
//   cgev notch                  the notch as "x y w h", integer global points, origin
//                               at the top-left of the main display
//   cgev move X Y               glide there quickly from where the cursor is — a
//                               single teleporting event does not fire tracking areas
//   cgev glide X1 Y1 X2 Y2 MS   move from one point to the other in 30 steps over MS ms
//   cgev click X Y              left click
//   cgev key CODE               press and release a key (53 = Escape)
//
// CGEvent and `screencapture -R` share this coordinate space, so a rectangle read
// from `notch` can be handed to either.
import AppKit

_ = NSApplication.shared

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
            mouseButton: .left)?.post(tap: .cghidEventTap)
}

let args = Array(CommandLine.arguments.dropFirst())
func number(_ index: Int) -> CGFloat {
    guard index < args.count, let value = Double(args[index]) else {
        FileHandle.standardError.write("cgev: missing or bad number at argument \(index + 1)\n".data(using: .utf8)!)
        exit(2)
    }
    return CGFloat(value)
}

switch args.first {
case "notch":
    // The auxiliary areas are the menu bar either side of the notch, in global
    // AppKit coordinates (origin bottom-left of the main display); the notch is
    // the gap between them — the same derivation as `IslandLayout.notchRect`.
    guard let main = NSScreen.screens.first,
          let screen = NSScreen.screens.first(where: {
              $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }),
          let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
    else {
        FileHandle.standardError.write("cgev: no screen with a notch\n".data(using: .utf8)!)
        exit(1)
    }
    let x = left.maxX - main.frame.minX
    let y = main.frame.maxY - left.maxY
    print(String(format: "%.0f %.0f %.0f %.0f", x, y, right.minX - left.maxX, left.height))
case "move":
    // AppKit's `NSTrackingArea` fires `mouseEntered` off the crossing, not just the
    // final position — a single event teleported straight to the target leaves the
    // island's hover never told the cursor passed through it. Eight steps in 80 ms
    // reads as instant to a human but still looks like a mouse sliding in to the
    // window server.
    let target = CGPoint(x: number(1), y: number(2))
    let start = CGEvent(source: nil)?.location ?? target
    let steps = 8
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        post(.mouseMoved, CGPoint(x: start.x + (target.x - start.x) * t,
                                  y: start.y + (target.y - start.y) * t))
        usleep(10_000)
    }
case "glide":
    let from = CGPoint(x: number(1), y: number(2)), to = CGPoint(x: number(3), y: number(4))
    let total = Double(number(5))
    for step in 1...30 {
        let t = CGFloat(step) / 30
        post(.mouseMoved, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(useconds_t(total * 1000 / 30))
    }
case "click":
    let point = CGPoint(x: number(1), y: number(2))
    post(.mouseMoved, point)
    usleep(50_000)
    post(.leftMouseDown, point)
    usleep(60_000)
    post(.leftMouseUp, point)
case "key":
    let code = CGKeyCode(Int(number(1)))
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
default:
    FileHandle.standardError.write("usage: cgev notch | move X Y | glide X1 Y1 X2 Y2 MS | click X Y | key CODE\n"
        .data(using: .utf8)!)
    exit(2)
}
