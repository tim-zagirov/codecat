import XCTest
import CoreGraphics
import ImageIO
@testable import CodeCatCore

/// Checks the registry against the real PNGs. This is the test that catches a typo
/// in a frame table before the app is ever launched.
///
/// It reaches the files through `#filePath` because the sheets live in the
/// `CodeCatApp` target's resources, and an executable target has no test bundle of
/// its own to read them from. That also means this test verifies the *sources*: that
/// the assets survive into the built `.app` is a separate check, in `make app`.
final class SkinAssetsTests: XCTestCase {

    private var skinsDirectory: URL {
        URL(fileURLWithPath: #filePath)            // .../Tests/CodeCatCoreTests/SkinAssetsTests.swift
            .deletingLastPathComponent()           // .../Tests/CodeCatCoreTests
            .deletingLastPathComponent()           // .../Tests
            .deletingLastPathComponent()           // repo root
            .appendingPathComponent("Sources/CodeCatApp/Skins")
    }

    func testSkinsDirectoryExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: skinsDirectory.path),
                      "Ассеты обликов не найдены: \(skinsDirectory.path)")
    }

    func testEveryDeclaredSheetExistsAndHoldsEveryDeclaredFrame() throws {
        for skin in MascotSkins.all where skin.isSpriteBased {
            let directory = skinsDirectory.appendingPathComponent(skin.directory!)
            // Highest frame index actually asked for, per sheet.
            var maxIndex: [String: Int] = [:]
            for animation in skin.animations.values {
                for frame in animation.frames {
                    maxIndex[frame.sheet] = max(maxIndex[frame.sheet] ?? 0, frame.index)
                }
            }
            for (sheet, highest) in maxIndex {
                let url = directory.appendingPathComponent(sheet)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "\(skin.id): нет файла \(url.path)")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return XCTFail("\(skin.id): не читается PNG \(sheet)")
                }
                let columns = image.width / skin.frameSize
                let rows = image.height / skin.frameSize
                XCTAssertGreaterThan(columns, 0, "\(skin.id)/\(sheet): ширина меньше кадра")
                XCTAssertGreaterThan(rows, 0, "\(skin.id)/\(sheet): высота меньше кадра")
                XCTAssertLessThan(highest, columns * rows,
                                  "\(skin.id)/\(sheet): кадр \(highest) вне листа \(columns)x\(rows)")
                XCTAssertEqual(image.width % skin.frameSize, 0,
                               "\(skin.id)/\(sheet): ширина не кратна кадру \(skin.frameSize)")
                XCTAssertEqual(image.height % skin.frameSize, 0,
                               "\(skin.id)/\(sheet): высота не кратна кадру \(skin.frameSize)")
            }
        }
    }

    /// The licence texts shipped by the authors are kept verbatim, not paraphrased.
    func testOriginalLicenceFilesAreKept() {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: skinsDirectory.appendingPathComponent("luizmelo/License.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: skinsDirectory.appendingPathComponent("CREDITS.md").path))
    }
}
