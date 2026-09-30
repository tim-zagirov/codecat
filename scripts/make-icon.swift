#!/usr/bin/env swift
//
// Draws CodeCat's app icon and menu-bar symbol and writes Resources/AppIcon.png
// (1024×1024), Resources/CodeCat.icns and Resources/Brand/menubar.pdf.
//
//   swift scripts/make-icon.swift
//
// The mark is Figma's (file MEQ6qhsFfgEzbwjrQxPbVO): the notch is the cat — a black
// island with ears, two pixel eyes and the rim light. Its vectors are the committed
// exports, read here rather than redrawn: Resources/Brand/icon-content.svg (node 21:9,
// the icon's content in a 412 pt box) and Resources/Brand/menubar-symbol.svg (node
// 22:6, the template with the eyes knocked out). The effects Figma exported as SVG
// filters and gradients are restated in `IconSpec`, each with its source. Changing
// the mark means re-exporting those nodes and running this script; the build only
// copies what it wrote.

import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Reading the SVGs

/// The path data of an SVG `d` attribute. Absolute `M L H V C Z` only — what Figma
/// wrote for the mark. Anything else stops the script with the command's name, so a
/// re-export that uses more cannot be drawn wrong in silence.
func svgPath(_ d: String) -> Path {
    // Every letter is a token — a command this reader does not know has to reach the
    // check below, not vanish and leave its numbers to the command before it. An
    // exponent's `e` never gets here: the number alternative has already taken it.
    let pattern = try! NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"#)
    let tokens = pattern.matches(in: d, range: NSRange(d.startIndex..., in: d)).map { String(d[Range($0.range, in: d)!]) }
    var path = Path()
    var i = 0
    var command: Character = "M"
    var current = CGPoint.zero
    func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
    func point() -> CGPoint { CGPoint(x: number(), y: number()) }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter {
            // Lower-case commands are relative; drawing them as absolute would put the
            // shape somewhere else without a word, so they stop here too.
            guard "MLHVCZ".contains(c) else { unsupported(c) }
            command = c
            i += 1
            if c == "Z" { path.closeSubpath(); continue }
        }
        switch command {
        case "M": current = point(); path.move(to: current); command = "L"
        case "L": current = point(); path.addLine(to: current)
        case "H": current.x = number(); path.addLine(to: current)
        case "V": current.y = number(); path.addLine(to: current)
        case "C":
            let c1 = point(), c2 = point(), end = point()
            path.addCurve(to: end, control1: c1, control2: c2)
            current = end
        default:
            unsupported(command)
        }
    }
    return path
}

func unsupported(_ command: Character) -> Never {
    FileHandle.standardError.write(Data("make-icon: SVG command \(command) is not supported\n".utf8))
    exit(1)
}

/// The first `attribute="…"` after `marker` in `svg`. The name is matched with the
/// space before it: `id="…"` ends in `d="`, and the menu-bar path's id comes first.
func attribute(_ name: String, after marker: String, in svg: String) -> String {
    guard let start = svg.range(of: marker),
          let open = svg.range(of: " \(name)=\"", range: start.upperBound..<svg.endIndex),
          let close = svg.range(of: "\"", range: open.upperBound..<svg.endIndex) else {
        FileHandle.standardError.write(Data("make-icon: no \(name) after \(marker)\n".utf8))
        exit(1)
    }
    return String(svg[open.upperBound..<close.lowerBound])
}

/// A `<rect>` by its Figma layer id. The marker ends with the closing quote so `Eye`
/// cannot match `Eye_2`.
func rect(id: String, in svg: String) -> CGRect {
    let marker = "id=\"\(id)\""
    func value(_ name: String) -> CGFloat {
        guard let v = Double(attribute(name, after: marker, in: svg)) else {
            FileHandle.standardError.write(Data("make-icon: \(name) of \(id) is not a number\n".utf8))
            exit(1)
        }
        return CGFloat(v)
    }
    return CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
}

// MARK: - The icon

/// Figma 07 "App icon · 512", node 21:8 and the SVG's filter and gradient, in the
/// 412 pt box the content was drawn in; the icon draws that box at 824 of 1024
/// (the macOS icon grid, spec §10).
enum IconSpec {
    static let canvas: CGFloat = 1024
    static let squircle = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let radius: CGFloat = 185                 // 92.5 at 412
    static let top = Color(red: 0x26 / 255, green: 0x2E / 255, blue: 0x59 / 255)
    static let bottom = Color(red: 0x5E / 255, green: 0x45 / 255, blue: 0x73 / 255)
    static let amber = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
    /// The island's glow: feOffset dy 9.6, feGaussianBlur 16, amber at 0.6.
    static let glowY: CGFloat = 9.6, glowRadius: CGFloat = 16, glowOpacity = 0.6
    /// The rim: 4.48 wide, round caps, amber 0.15 → amber → #FFF5E0 at the middle.
    static let rimWidth: CGFloat = 4.48
    static let rimStops: [Gradient.Stop] = [
        .init(color: amber.opacity(0.15), location: 0), .init(color: amber, location: 0.28),
        .init(color: Color(red: 1, green: 0xF5 / 255, blue: 0xE0 / 255), location: 0.5),
        .init(color: amber, location: 0.72), .init(color: amber.opacity(0.15), location: 1),
    ]
}

struct Mark {
    let island: Path
    let rim: Path
    let eyes: [CGRect]
    let highlights: [CGRect]
    /// The rim gradient's `x1`/`x2`, which the SVG gives in the 412 box.
    let rimFrom: CGFloat, rimTo: CGFloat
}

struct IconView: View {
    let mark: Mark

    var body: some View {
        let box: CGFloat = 412
        ZStack {
            RoundedRectangle(cornerRadius: IconSpec.radius, style: .continuous)
                .fill(LinearGradient(colors: [IconSpec.top, IconSpec.bottom], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: IconSpec.radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 2))
                // Figma's drop shadow, y 5 blur 12 at 412, doubled for the 824 tile.
                // Figma's blur is twice the Gaussian's σ (the island's blur 32 is the
                // SVG's stdDeviation 16) and `radius` acts as σ: 12, not 24 — at 24 the
                // shadow reached twice as far below the tile as Figma's export.
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 10)
                .frame(width: IconSpec.squircle.width, height: IconSpec.squircle.height)

            ZStack(alignment: .topLeading) {
                // The island carries a 1 pt black stroke in the export as well as its
                // fill; both are drawn so its edge sits where Figma's does.
                ZStack {
                    mark.island.fill(Color.black)
                    mark.island.stroke(Color.black, lineWidth: 1)
                }
                .compositingGroup()
                .shadow(color: IconSpec.amber.opacity(IconSpec.glowOpacity),
                        radius: IconSpec.glowRadius, x: 0, y: IconSpec.glowY)

                mark.rim.stroke(
                    LinearGradient(stops: IconSpec.rimStops,
                                   startPoint: UnitPoint(x: mark.rimFrom / box, y: 0.5),
                                   endPoint: UnitPoint(x: mark.rimTo / box, y: 0.5)),
                    style: StrokeStyle(lineWidth: IconSpec.rimWidth, lineCap: .round))

                ForEach(mark.eyes.indices, id: \.self) { Path(mark.eyes[$0]).fill(IconSpec.amber) }
                ForEach(mark.highlights.indices, id: \.self) { Path(mark.highlights[$0]).fill(Color.white.opacity(0.9)) }
            }
            .frame(width: box, height: box)
            .scaleEffect(IconSpec.squircle.width / box)
        }
        .frame(width: IconSpec.canvas, height: IconSpec.canvas)
    }
}

/// The icon at `size` px: the same view rasterised at `size / 1024`, not the 1024
/// image resampled, so 16 and 32 px get their own rasterisation.
func renderIcon(_ mark: Mark, size: Int) -> CGImage {
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: IconView(mark: mark))
        renderer.scale = CGFloat(size) / IconSpec.canvas
        guard let image = renderer.cgImage, image.width == size, image.height == size else {
            FileHandle.standardError.write(Data("make-icon: could not render the icon at \(size) px\n".utf8))
            exit(1)
        }
        return image
    }
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        exit(1)
    }
}

// MARK: - The menu-bar template

/// The symbol at 10 pt tall (the SVG's 90 → 10), filled black with the even-odd
/// rule — the eyes are its holes — into an 18 × 10 pt PDF that `BrandMark` loads as
/// a template.
func writeMenuBarPDF(_ symbol: Path, to url: URL) {
    let scale: CGFloat = 10 / 90
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 10)
    guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        exit(1)
    }
    ctx.beginPDFPage(nil)
    // The SVG's y grows downward; PDF's grows upward.
    ctx.translateBy(x: 0, y: mediaBox.height)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.addPath(symbol.cgPath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath(using: .evenOdd)
    ctx.endPDFPage()
    ctx.closePDF()
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let brand = resources.appendingPathComponent("Brand")
guard FileManager.default.fileExists(atPath: brand.path) else {
    FileHandle.standardError.write(Data("run this from the repository root\n".utf8))
    exit(1)
}

func read(_ name: String) -> String {
    guard let text = try? String(contentsOf: brand.appendingPathComponent(name), encoding: .utf8) else {
        FileHandle.standardError.write(Data("make-icon: cannot read Resources/Brand/\(name)\n".utf8))
        exit(1)
    }
    return text
}

let iconSVG = read("icon-content.svg")
let mark = Mark(
    island: svgPath(attribute("d", after: "<g id=\"Cat island\"", in: iconSVG)),
    rim: svgPath(attribute("d", after: "id=\"Rim\"", in: iconSVG)),
    eyes: [rect(id: "Eye", in: iconSVG), rect(id: "Eye_2", in: iconSVG)],
    highlights: [rect(id: "Rectangle", in: iconSVG), rect(id: "Rectangle_2", in: iconSVG)],
    rimFrom: CGFloat(Double(attribute("x1", after: "<linearGradient", in: iconSVG))!),
    rimTo: CGFloat(Double(attribute("x2", after: "<linearGradient", in: iconSVG))!))

write(renderIcon(mark, size: 1024), to: resources.appendingPathComponent("AppIcon.png"))

// .iconset → iconutil. Every size Apple asks for, including the @2x variants:
// iconutil rejects an incomplete set rather than filling the gaps itself.
let iconset = resources.appendingPathComponent("CodeCat.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(renderIcon(mark, size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    write(renderIcon(mark, size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path,
                      "-o", resources.appendingPathComponent("CodeCat.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)

let menubarSVG = read("menubar-symbol.svg")
writeMenuBarPDF(svgPath(attribute("d", after: "<path", in: menubarSVG)),
                to: brand.appendingPathComponent("menubar.pdf"))

print("wrote Resources/AppIcon.png, Resources/CodeCat.icns and Resources/Brand/menubar.pdf")
