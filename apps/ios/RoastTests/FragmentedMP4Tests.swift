import XCTest
@testable import Roast

/// YouTube's DASH files declare their full duration in a moov that holds no samples, so
/// AVFoundation counts the length twice; the import clears those declared durations.
final class FragmentedMP4Tests: XCTestCase {
    private func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(payload.count + 8).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(type.utf8))
        data.append(payload)
        return data
    }
    private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    /// version 0: flags, creation, modification, then timescale + duration (mvhd/mdhd) or id + reserved + duration (tkhd).
    private func header(_ type: String, duration: UInt32) -> Data {
        let common = Data(count: 4) + be32(1) + be32(2)
        let body = type == "tkhd" ? common + be32(1) + be32(0) + be32(duration) + Data(count: 60)
                                  : common + be32(60_000) + be32(duration) + Data(count: 80)
        return box(type, body)
    }
    private func movie(fragmented: Bool, duration: UInt32) -> Data {
        let trak = box("trak", header("tkhd", duration: duration) + box("mdia", header("mdhd", duration: duration)))
        let moov = box("moov", header("mvhd", duration: duration) + (fragmented ? box("mvex", box("trex", Data(count: 24))) : Data()) + trak)
        return box("ftyp", Data("dash".utf8) + Data(count: 4)) + moov + box("mdat", Data(repeating: 7, count: 32))
    }
    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFragmentedFileHasItsDeclaredDurationsCleared() throws {
        let original = movie(fragmented: true, duration: 25_540_515)
        let file = try write(original)
        XCTAssertTrue(try DirectVideoPreparer.normalizeFragmentedMP4(file))
        let patched = try Data(contentsOf: file)
        XCTAssertEqual(patched.count, original.count)
        XCTAssertEqual(patched, movie(fragmented: true, duration: 0), "Only the three declared durations change.")
        // Running it again is harmless.
        XCTAssertTrue(try DirectVideoPreparer.normalizeFragmentedMP4(file))
        XCTAssertEqual(try Data(contentsOf: file), patched)
    }

    func testRegularFileIsLeftUntouched() throws {
        let original = movie(fragmented: false, duration: 25_540_515)
        let file = try write(original)
        XCTAssertFalse(try DirectVideoPreparer.normalizeFragmentedMP4(file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
