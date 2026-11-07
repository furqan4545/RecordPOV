import Foundation
import XCTest
@testable import Roast

final class PieceDownloadTests: XCTestCase {
    private let mebibytes10: Int64 = 10 * 1024 * 1024

    func testSmallFileIsOnePieceCoveringEveryByte() {
        XCTAssertEqual(BackgroundMediaDownloads.pieceSize, mebibytes10)
        XCTAssertEqual(BackgroundMediaDownloads.pieceRanges(total: 6_890_574), [0...6_890_573])
    }

    func testLargeFileIsSplitIntoTenMiBPiecesWithAShorterLastOne() {
        let ranges = BackgroundMediaDownloads.pieceRanges(total: 106_424_608)
        XCTAssertEqual(ranges.count, 11)
        XCTAssertEqual(ranges.first, 0...10_485_759)
        XCTAssertEqual(ranges[1], 10_485_760...20_971_519)
        XCTAssertEqual(ranges.last, 104_857_600...106_424_607)
        for (previous, next) in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(previous.upperBound + 1, next.lowerBound) }
        XCTAssertEqual(ranges.dropLast().allSatisfy { $0.upperBound - $0.lowerBound + 1 == mebibytes10 }, true)
        XCTAssertEqual(ranges.reduce(Int64(0)) { $0 + $1.upperBound - $1.lowerBound + 1 }, 106_424_608)
        XCTAssertTrue(BackgroundMediaDownloads.pieceRanges(total: 0).isEmpty)
    }

    func testTotalSizeIsReadFromClenOrAContentRange() {
        XCTAssertEqual(BackgroundMediaDownloads.declaredLength(URL(string: "https://rr1---sn.test.googlevideo.com/videoplayback?itag=137&clen=106424608&dur=300")!), 106_424_608)
        XCTAssertNil(BackgroundMediaDownloads.declaredLength(URL(string: "https://rr1---sn.test.googlevideo.com/videoplayback?itag=137")!))
        XCTAssertEqual(BackgroundMediaDownloads.contentRangeTotal("bytes 0-0/6890574"), 6_890_574)
        XCTAssertNil(BackgroundMediaDownloads.contentRangeTotal("bytes 0-0/*"))
        XCTAssertNil(BackgroundMediaDownloads.contentRangeTotal(nil))
    }

    func testStalledDownloadIsRetriedAfterThirtySecondsAndFailsAfterFiveAttempts() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(BackgroundMediaDownloads.stallDecision(lastBytesAt: start, now: start.addingTimeInterval(29.9), attempts: 1), .keep)
        XCTAssertEqual(BackgroundMediaDownloads.stallDecision(lastBytesAt: start, now: start.addingTimeInterval(29.9), attempts: 5), .keep)
        for attempts in 1...4 {
            XCTAssertEqual(BackgroundMediaDownloads.stallDecision(lastBytesAt: start, now: start.addingTimeInterval(30), attempts: attempts), .retry, "\(attempts)")
        }
        XCTAssertEqual(BackgroundMediaDownloads.stallDecision(lastBytesAt: start, now: start.addingTimeInterval(30), attempts: 5), .fail)
        XCTAssertEqual(BackgroundMediaDownloads.stallCheckInterval, 5)
    }
}
