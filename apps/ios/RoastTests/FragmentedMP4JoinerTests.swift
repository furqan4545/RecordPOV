import XCTest
@testable import Roast

/// The YouTube join: two fragmented files (video only, audio only) become one regular MP4
/// with the same compressed samples and timing.
final class FragmentedMP4JoinerTests: XCTestCase {
    private func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }
    private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private func u32(_ data: Data, _ at: Int) -> UInt32 {
        data[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    private func boxes(_ data: Data, _ range: Range<Int>) -> [(type: String, content: Int, end: Int)] {
        var result: [(type: String, content: Int, end: Int)] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            let length = Int(u32(data, position))
            guard length >= 8, position + length <= range.upperBound else { break }
            result.append((String(decoding: data[position + 4..<position + 8], as: UTF8.self), position + 8, position + length))
            position += length
        }
        return result
    }
    /// The content range of the box at `path` ("moov/trak[1]/mdia/mdhd").
    private func find(_ path: String, in data: Data) throws -> Range<Int> {
        var range = 0..<data.count
        for part in path.split(separator: "/") {
            let name = String(part.prefix(4))
            let index = part.count > 4 ? Int(part.dropFirst(5).dropLast()) ?? 0 : 0
            let matches = boxes(data, range).filter { $0.type == name }
            guard index < matches.count else { throw Missing(path: path) }
            range = matches[index].content..<matches[index].end
        }
        return range
    }
    private struct Missing: Error { let path: String }
    private func has(_ path: String, in data: Data) -> Bool { (try? find(path, in: data)) != nil }
    /// (count, value) pairs of an stts, ctts or stsc-like table with `width` words per entry.
    private func table(_ data: Data, _ range: Range<Int>, width: Int) -> [[UInt32]] {
        let count = Int(u32(data, range.lowerBound + 4))
        return (0..<count).map { entry in (0..<width).map { u32(data, range.lowerBound + 8 + (entry * width + $0) * 4) } }
    }

    /// version 0 headers with the declared durations cleared, as the import leaves them.
    private func mvhd(_ timescale: UInt32) -> Data {
        box("mvhd", Data(count: 12) + be32(timescale) + be32(0) + be32(0x0001_0000) + Data(count: 72) + be32(2))
    }
    private func tkhd() -> Data { box("tkhd", be32(3) + Data(count: 8) + be32(1) + Data(count: 8) + Data(count: 60)) }
    private func mdhd(_ timescale: UInt32) -> Data { box("mdhd", Data(count: 12) + be32(timescale) + be32(0) + be32(0x55C4_0000)) }
    private func movie(handler: String, entry: String, timescale: UInt32, edit: Data, header: Data) -> Data {
        let stsd = box("stsd", be32(0) + be32(1) + box(entry, Data(repeating: 1, count: 28)))
        let empty = box("stts", Data(count: 8)) + box("stsc", Data(count: 8)) + box("stco", Data(count: 8)) + box("stsz", Data(count: 12))
        let minf = box("minf", box("dinf", box("dref", be32(0) + be32(1) + box("url ", be32(1)))) + box("stbl", stsd + empty) + header)
        let hdlr = box("hdlr", be32(0) + be32(0) + Data(handler.utf8) + Data(count: 13))
        let trak = box("trak", tkhd() + edit + box("mdia", mdhd(timescale) + hdlr + minf))
        let trex = box("trex", be32(0) + be32(1) + be32(1) + be32(0) + be32(0) + be32(0))
        return box("ftyp", Data("dash".utf8) + Data(count: 4)) + box("moov", mvhd(timescale) + box("mvex", trex) + trak)
    }
    /// One moof + mdat. Each run is (sample fields, sizes); a run without a data offset follows the previous one.
    private func fragment(sequence: UInt32, tfhd: Data, decodeTime: UInt32,
                          runs: [(flags: UInt32, samples: [Data], sizes: [UInt32], withOffset: Bool)]) -> Data {
        func moof(_ offsets: [UInt32]) -> Data {
            var trafBody = box("tfhd", tfhd) + box("tfdt", be32(0) + be32(decodeTime))
            for (index, run) in runs.enumerated() {
                trafBody += box("trun", be32(run.flags | (run.withOffset ? 1 : 0)) + be32(UInt32(run.samples.count))
                                + (run.withOffset ? be32(offsets[index]) : Data()) + run.samples.reduce(Data(), +))
            }
            return box("moof", box("mfhd", be32(0) + be32(sequence)) + box("traf", trafBody))
        }
        let size = moof(Array(repeating: 0, count: runs.count)).count
        var offsets: [UInt32] = [], position = UInt32(size + 8)
        for run in runs { offsets.append(position); position += run.sizes.reduce(0, +) }
        return moof(offsets) + box("mdat", Data(count: Int(runs.flatMap { $0.sizes }.reduce(0, +))))
    }
    private var videoBytes: [Data] = []
    private var audioBytes: [Data] = []

    /// 5 video samples (3 + 2 in two fragments, 1000 ticks each at 60000, sync at 1 and 4,
    /// composition offsets) and 4 audio samples (2 + 1 + 1, 1024 ticks at 44100, all sync).
    private func pair() throws -> (video: URL, audio: URL) {
        let videoSizes: [[UInt32]] = [[5, 6, 7], [8, 9]]
        let videoFlags: [[UInt32]] = [[0x0200_0000, 0x0101_0000, 0x0101_0000], [0x0200_0000, 0x0101_0000]]
        let offsets: [[UInt32]] = [[1000, 2000, 0], [1000, 1000]]
        let elst = box("edts", box("elst", be32(0) + be32(1) + be32(5000) + be32(1000) + be32(0x0001_0000)))
        var video = movie(handler: "vide", entry: "avc1", timescale: 60_000, edit: elst, header: box("vmhd", be32(1) + Data(count: 8)))
        var marker: UInt8 = 0x10
        videoBytes = []
        for (index, sizes) in videoSizes.enumerated() {
            let samples = sizes.indices.map { be32(sizes[$0]) + be32(videoFlags[index][$0]) + be32(offsets[index][$0]) }
            var piece = fragment(sequence: UInt32(index + 1), tfhd: be32(0x02000A) + be32(1) + be32(1) + be32(1000),
                                 decodeTime: UInt32(index * 3000), runs: [(0xE00, samples, sizes, true)])
            // Give every sample its own byte value so chunk offsets can be checked.
            var cursor = piece.count - Int(sizes.reduce(0, +))
            for size in sizes {
                let bytes = Data(repeating: marker, count: Int(size))
                piece.replaceSubrange(cursor..<cursor + Int(size), with: bytes)
                videoBytes.append(bytes); cursor += Int(size); marker += 1
            }
            video += piece
        }
        var audio = movie(handler: "soun", entry: "mp4a", timescale: 44_100, edit: Data(), header: box("smhd", Data(count: 8)))
        let audioRuns: [[[UInt32]]] = [[[3, 4]], [[5], [6]]]
        marker = 0x80
        audioBytes = []
        for (index, runs) in audioRuns.enumerated() {
            let total = runs.joined().reduce(0, +)
            var piece = fragment(sequence: UInt32(index + 1), tfhd: be32(0x02002A) + be32(1) + be32(1) + be32(1024) + be32(0),
                                 decodeTime: UInt32(index * 2048),
                                 runs: runs.enumerated().map { (0x200, $1.map(be32), $1, $0 == 0) })
            var cursor = piece.count - Int(total)
            for size in runs.joined() {
                let bytes = Data(repeating: marker, count: Int(size))
                piece.replaceSubrange(cursor..<cursor + Int(size), with: bytes)
                audioBytes.append(bytes); cursor += Int(size); marker += 1
            }
            audio += piece
        }
        return (try write(video), try write(audio))
    }
    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func output() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testJoinWritesOneRegularMovieWithEverySample() throws {
        let (video, audio) = try pair()
        let target = output()
        try FragmentedMP4Joiner.join(video: video, audio: audio, to: target)
        let data = try Data(contentsOf: target)
        XCTAssertEqual(boxes(data, 0..<data.count).map(\.type), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "isom")
        XCTAssertFalse(has("moov/mvex", in: data))
        let mvhd = try find("moov/mvhd", in: data)
        XCTAssertEqual(u32(data, mvhd.lowerBound + 12), 60_000)
        XCTAssertEqual(u32(data, mvhd.lowerBound + 16), 5573, "The longest track: 4096 audio ticks at 44100 in the movie timescale.")
        XCTAssertEqual(u32(data, mvhd.upperBound - 4), 3)

        // Video: track 1, durations from the samples, the edit list kept.
        let vtkhd = try find("moov/trak[0]/tkhd", in: data)
        XCTAssertEqual(u32(data, vtkhd.lowerBound + 12), 1)
        XCTAssertEqual(u32(data, vtkhd.lowerBound + 20), 5000)
        XCTAssertEqual(u32(data, try find("moov/trak[0]/mdia/mdhd", in: data).lowerBound + 16), 5000)
        let elst = try find("moov/trak[0]/edts/elst", in: data)
        XCTAssertEqual(table(data, elst, width: 3), [[5000, 1000, 0x0001_0000]])
        let vstbl = "moov/trak[0]/mdia/minf/stbl/"
        XCTAssertEqual(table(data, try find(vstbl + "stts", in: data), width: 2), [[5, 1000]])
        XCTAssertEqual(table(data, try find(vstbl + "ctts", in: data), width: 2), [[1, 1000], [1, 2000], [1, 0], [2, 1000]])
        XCTAssertEqual(data[try find(vstbl + "ctts", in: data).lowerBound], 0, "No negative offsets: version 0.")
        XCTAssertEqual(table(data, try find(vstbl + "stss", in: data), width: 1), [[1], [4]])
        XCTAssertEqual(table(data, try find(vstbl + "stsc", in: data), width: 3), [[1, 3, 1], [2, 2, 1]])
        let vstsz = try find(vstbl + "stsz", in: data)
        XCTAssertEqual(u32(data, vstsz.lowerBound + 8), 5)
        XCTAssertEqual((0..<5).map { u32(data, vstsz.lowerBound + 12 + $0 * 4) }, [5, 6, 7, 8, 9])
        let vstco = table(data, try find(vstbl + "stco", in: data), width: 1).map { Int($0[0]) }
        XCTAssertEqual(vstco.count, 2)

        // Audio: track 2, every sample a sync sample, no composition offsets, no edit list.
        let atkhd = try find("moov/trak[1]/tkhd", in: data)
        XCTAssertEqual(u32(data, atkhd.lowerBound + 12), 2)
        XCTAssertEqual(u32(data, atkhd.lowerBound + 20), 5573)
        XCTAssertEqual(u32(data, try find("moov/trak[1]/mdia/mdhd", in: data).lowerBound + 16), 4096)
        XCTAssertFalse(has("moov/trak[1]/edts", in: data))
        let astbl = "moov/trak[1]/mdia/minf/stbl/"
        XCTAssertFalse(has(astbl + "ctts", in: data))
        XCTAssertFalse(has(astbl + "stss", in: data))
        XCTAssertEqual(table(data, try find(astbl + "stts", in: data), width: 2), [[4, 1024]])
        XCTAssertEqual(table(data, try find(astbl + "stsc", in: data), width: 3), [[1, 2, 1], [2, 1, 1]])
        let astsz = try find(astbl + "stsz", in: data)
        XCTAssertEqual((0..<4).map { u32(data, astsz.lowerBound + 12 + $0 * 4) }, [3, 4, 5, 6])
        let astco = table(data, try find(astbl + "stco", in: data), width: 1).map { Int($0[0]) }
        XCTAssertEqual(astco.count, 3)

        // The sample description is copied byte for byte.
        let source = try Data(contentsOf: video)
        let stsd = try find(vstbl + "stsd", in: data), sourceStsd = try find("moov/trak/mdia/minf/stbl/stsd", in: source)
        XCTAssertEqual(data[stsd], source[sourceStsd])

        // Chunks interleaved by decode time (video 0, audio 0, audio 2048, video 3000, audio 3072),
        // and every chunk offset points at that chunk's own sample bytes.
        XCTAssertEqual([vstco[0], astco[0], astco[1], vstco[1], astco[2]], [vstco[0], astco[0], astco[1], vstco[1], astco[2]].sorted())
        let mdat = try find("mdat", in: data)
        XCTAssertEqual(vstco[0], mdat.lowerBound)
        XCTAssertEqual(data[vstco[0]..<vstco[0] + 18], videoBytes[0..<3].reduce(Data(), +))
        XCTAssertEqual(data[vstco[1]..<vstco[1] + 17], videoBytes[3..<5].reduce(Data(), +))
        XCTAssertEqual(data[astco[0]..<astco[0] + 7], audioBytes[0..<2].reduce(Data(), +))
        XCTAssertEqual(data[astco[1]..<astco[1] + 5], audioBytes[2])
        XCTAssertEqual(data[astco[2]..<astco[2] + 6], audioBytes[3])
        XCTAssertEqual(mdat.count, 18 + 17 + 7 + 5 + 6)
    }

    func testTruncatedInputThrows() throws {
        let (video, audio) = try pair()
        let source = try Data(contentsOf: video)
        let cut = try write(source.prefix(source.count - 3))
        XCTAssertThrowsError(try FragmentedMP4Joiner.join(video: cut, audio: audio, to: output()))
    }

    func testMalformedSampleCountThrows() throws {
        let (video, audio) = try pair()
        var source = try Data(contentsOf: video)
        // The first trun's sample count far beyond what its box holds.
        let trun = source.range(of: Data("trun".utf8))!.upperBound
        source.replaceSubrange(trun + 4..<trun + 8, with: be32(0x7FFF_FFFF))
        XCTAssertThrowsError(try FragmentedMP4Joiner.join(video: try write(source), audio: audio, to: output()))
    }
}
