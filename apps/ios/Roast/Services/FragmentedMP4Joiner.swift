import Foundation

/// Joins YouTube's fragmented (DASH) video-only and audio-only MP4 files into one regular MP4
/// by copying the compressed samples as they are. Nothing is decoded or encoded, and no declared
/// duration of the inputs is used: every duration comes from the samples themselves.
enum FragmentedMP4Joiner {
    enum JoinError: LocalizedError {
        /// Valid input this joiner does not handle (the regular export path runs instead).
        case unsupported(String)
        /// Damaged or truncated input.
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let reason): return "Unsupported fragmented MP4: \(reason)"
            case .malformed(let reason): return "Malformed fragmented MP4: \(reason)"
            }
        }
    }

    /// Writes `output` (a new file) with the video as track 1 and the audio as track 2.
    /// Synchronous; call it off the main actor. Checks for task cancellation between chunks.
    static func join(video: URL, audio: URL, to output: URL) throws {
        let videoHandle = try FileHandle(forReadingFrom: video)
        defer { try? videoHandle.close() }
        let audioHandle = try FileHandle(forReadingFrom: audio)
        defer { try? audioHandle.close() }
        let tracks = [try parse(videoHandle), try parse(audioHandle)]
        let movieTimescale = tracks[0].movieTimescale
        // Chunks of both tracks in decode-time order; each keeps the order within its own track.
        var order: [(track: Int, chunk: Chunk)] = []
        var next = [0, 0]
        while next[0] < tracks[0].chunks.count || next[1] < tracks[1].chunks.count {
            let pick: Int
            if next[1] >= tracks[1].chunks.count { pick = 0 }
            else if next[0] >= tracks[0].chunks.count { pick = 1 }
            else {
                let videoTime = Double(tracks[0].chunks[next[0]].decodeTime) / Double(tracks[0].mediaTimescale)
                let audioTime = Double(tracks[1].chunks[next[1]].decodeTime) / Double(tracks[1].mediaTimescale)
                pick = videoTime <= audioTime ? 0 : 1
            }
            order.append((pick, tracks[pick].chunks[next[pick]]))
            next[pick] += 1
        }
        var payload: UInt64 = 0
        var relative: [[UInt64]] = [[], []]
        for (track, chunk) in order {
            relative[track].append(payload)
            payload = try add(payload, chunk.length)
        }
        let ftyp = box("ftyp", Data("isom".utf8) + be32(0x200) + Data("isomiso2avc1mp41".utf8))
        let mdatHeader = payload + 8 > UInt64(UInt32.max)
            ? be32(1) + Data("mdat".utf8) + be64(try add(payload, 16))
            : be32(UInt32(payload + 8)) + Data("mdat".utf8)
        // The moov's size depends only on stco versus co64, so measure it first, then write the real offsets.
        func moov(base: UInt64, wide: Bool) throws -> Data {
            try movie(tracks, movieTimescale: movieTimescale,
                      offsets: relative.map { $0.map { $0 + base } }, wide: wide)
        }
        var wide = false
        var base = UInt64(ftyp.count) + UInt64(try moov(base: 0, wide: false).count) + UInt64(mdatHeader.count)
        if try add(base, relative.joined().max() ?? 0) >= 1 << 32 {
            wide = true
            base = UInt64(ftyp.count) + UInt64(try moov(base: 0, wide: true).count) + UInt64(mdatHeader.count)
        }
        let header = try moov(base: base, wide: wide)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        try writer.write(contentsOf: ftyp + header + mdatHeader)
        let handles = [videoHandle, audioHandle]
        for (track, chunk) in order {
            if Task.isCancelled { throw CancellationError() }
            try handles[track].seek(toOffset: chunk.offset)
            var remaining = chunk.length
            while remaining > 0 {
                let count = Int(min(remaining, 1 << 20))
                // Without the pool every read piece stays alive until join returns.
                try autoreleasepool {
                    guard let piece = try handles[track].read(upToCount: count), piece.count == count else { throw JoinError.malformed("sample data is cut off") }
                    try writer.write(contentsOf: piece)
                }
                remaining -= UInt64(count)
            }
        }
    }

    // MARK: - Input

    private struct Box {
        let type: String
        let start: Int
        let content: Int
        let end: Int
    }
    private struct Chunk {
        let offset: UInt64
        let length: UInt64
        let samples: Int
        let decodeTime: UInt64
    }
    private struct Track {
        let movieTimescale: UInt32
        let mediaTimescale: UInt32
        let mvhd: Data
        let tkhd: Data
        let mdhd: Data
        let hdlr: Data
        /// Every minf child except stbl (vmhd or smhd, dinf), byte for byte.
        let minfHeaders: [Data]
        let stsd: Data
        let elst: (version: UInt8, entries: [(duration: UInt64, mediaTime: Int64, rate: UInt32)])?
        var sizes: [UInt32] = []
        var durations: [UInt32] = []
        var compositionOffsets: [Int64] = []
        var sync: [Bool] = []
        var chunks: [Chunk] = []
    }
    private struct Reader {
        let data: Data
        var position: Int
        let end: Int
        init(_ data: Data, _ range: Range<Int>) { self.data = data; position = range.lowerBound; end = range.upperBound }
        mutating func uint(_ count: Int) throws -> UInt64 {
            guard count <= end - position else { throw JoinError.malformed("a box is too short") }
            var value: UInt64 = 0
            for index in position..<position + count { value = value << 8 | UInt64(data[index]) }
            position += count
            return value
        }
        mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
        mutating func skip(_ count: Int) throws {
            guard count <= end - position else { throw JoinError.malformed("a box is too short") }
            position += count
        }
    }

    private static func parse(_ handle: FileHandle) throws -> Track {
        let fileSize = try handle.seekToEnd()
        // Top-level boxes: one moov, then the moof boxes in file order; sidx, mdat and the rest are skipped.
        var moov: Data?
        var moofs: [(start: UInt64, content: UInt64, end: UInt64)] = []
        var offset: UInt64 = 0
        while offset < fileSize {
            guard fileSize - offset >= 8 else { throw JoinError.malformed("trailing bytes") }
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { throw JoinError.malformed("box header is cut off") }
            var reader = Reader(header, 0..<header.count)
            var length = try reader.uint(4)
            let type = String(decoding: header[4..<8], as: UTF8.self)
            try reader.skip(4)
            if length == 1 { length = try reader.uint(8) } else if length == 0 { length = fileSize - offset }
            let headerLength = UInt64(reader.position)
            guard length >= headerLength, length <= fileSize - offset else { throw JoinError.malformed("\(type) box is cut off") }
            if type == "moov" || type == "moof" {
                guard length - headerLength <= 64 << 20 else { throw JoinError.unsupported("\(type) box is too large") }
                if type == "moov" {
                    guard moov == nil else { throw JoinError.unsupported("more than one moov") }
                    try handle.seek(toOffset: offset + headerLength)
                    guard let body = try handle.read(upToCount: Int(length - headerLength)),
                          body.count == Int(length - headerLength) else { throw JoinError.malformed("moov is cut off") }
                    moov = body
                } else {
                    moofs.append((offset, offset + headerLength, offset + length))
                }
            }
            offset += length
        }
        guard let moov else { throw JoinError.malformed("no moov") }
        var track = try movieHeader(moov)
        let trex = try defaults(moov, trackID: try trackID(track.tkhd))
        var decodeTime: UInt64 = 0
        var sampleBytes: UInt64 = 0
        for moof in moofs {
            try handle.seek(toOffset: moof.content)
            guard let body = try handle.read(upToCount: Int(moof.end - moof.content)),
                  body.count == Int(moof.end - moof.content) else { throw JoinError.malformed("moof is cut off") }
            var previousTrafEnd: UInt64?
            for traf in try children(body, 0..<body.count) where traf.type == "traf" {
                let parts = try children(body, traf.content..<traf.end)
                guard let tfhd = parts.first(where: { $0.type == "tfhd" }), parts.filter({ $0.type == "tfhd" }).count == 1 else { throw JoinError.malformed("traf without one tfhd") }
                var reader = Reader(body, tfhd.content..<tfhd.end)
                let flags = UInt32(try reader.uint(4) & 0xFFFFFF)
                guard try reader.u32() == trex.trackID else { throw JoinError.unsupported("fragment of another track") }
                let base = try flags & 0x1 != 0 ? reader.uint(8)
                    : flags & 0x20000 != 0 ? moof.start : (previousTrafEnd ?? moof.start)
                let descriptionIndex = try flags & 0x2 != 0 ? reader.u32() : trex.descriptionIndex
                let defaultDuration = try flags & 0x8 != 0 ? reader.u32() : trex.duration
                let defaultSize = try flags & 0x10 != 0 ? reader.u32() : trex.size
                let defaultFlags = try flags & 0x20 != 0 ? reader.u32() : trex.flags
                guard descriptionIndex == 1 else { throw JoinError.unsupported("sample description \(descriptionIndex)") }
                // An empty-duration fragment is a gap in time, which stts cannot express either.
                guard flags & 0x10000 == 0 || defaultDuration == 0 else { throw JoinError.unsupported("empty-duration fragment") }
                if let tfdt = parts.first(where: { $0.type == "tfdt" }) {
                    var reader = Reader(body, tfdt.content..<tfdt.end)
                    let version = try reader.uint(4) >> 24
                    // A gap or overlap between fragments cannot be expressed by stts alone.
                    guard try reader.uint(version == 1 ? 8 : 4) == decodeTime else { throw JoinError.unsupported("fragment decode times are not continuous") }
                }
                var dataEnd = base
                for trun in parts where trun.type == "trun" {
                    var reader = Reader(body, trun.content..<trun.end)
                    let word = try reader.uint(4)
                    let version = word >> 24, runFlags = word & 0xFFFFFF
                    let count = try reader.uint(4)
                    let dataOffset: Int64? = try runFlags & 0x1 != 0 ? Int64(Int32(bitPattern: reader.u32())) : nil
                    let firstFlags: UInt32? = try runFlags & 0x4 != 0 ? reader.u32() : nil
                    let stride = [0x100, 0x200, 0x400, 0x800].filter { runFlags & UInt64($0) != 0 }.count * 4
                    guard stride > 0 ? count <= UInt64(reader.end - reader.position) / UInt64(stride)
                                     : defaultSize > 0 else { throw JoinError.malformed("trun sample count") }
                    guard count == 0 || flags & 0x10000 == 0 else { throw JoinError.malformed("samples in an empty fragment") }
                    if count == 0 { continue }
                    let start: UInt64
                    if let dataOffset {
                        let (signed, overflow) = Int64(clamping: base).addingReportingOverflow(dataOffset)
                        guard !overflow, signed >= 0 else { throw JoinError.malformed("data offset") }
                        start = UInt64(signed)
                    } else { start = dataEnd }
                    if stride == 0 {
                        // Every sample has the default size, so the count must fit the bytes after start
                        // and the file's bytes not yet used by earlier runs.
                        let (bytes, overflow) = count.multipliedReportingOverflow(by: UInt64(defaultSize))
                        guard !overflow, start <= fileSize, bytes <= fileSize - start, bytes <= fileSize - sampleBytes else { throw JoinError.malformed("sample data is cut off") }
                    }
                    var length: UInt64 = 0
                    let firstSample = track.sizes.count
                    for index in 0..<Int(count) {
                        let duration = try runFlags & 0x100 != 0 ? reader.u32() : defaultDuration
                        let size = try runFlags & 0x200 != 0 ? reader.u32() : defaultSize
                        var sampleFlags = index == 0 ? firstFlags ?? defaultFlags : defaultFlags
                        if runFlags & 0x400 != 0 { sampleFlags = try reader.u32() }
                        let raw = try runFlags & 0x800 != 0 ? reader.u32() : 0
                        track.durations.append(duration)
                        track.sizes.append(size)
                        track.sync.append(sampleFlags & 0x10000 == 0)
                        track.compositionOffsets.append(version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw)))
                        length = try add(length, UInt64(size))
                    }
                    guard try add(start, length) <= fileSize else { throw JoinError.malformed("sample data is cut off") }
                    // Sample data of a valid file never overlaps, so all of it fits the file once.
                    sampleBytes = try add(sampleBytes, length)
                    guard sampleBytes <= fileSize else { throw JoinError.malformed("sample data overlaps") }
                    track.chunks.append(Chunk(offset: start, length: length, samples: track.sizes.count - firstSample, decodeTime: decodeTime))
                    for duration in track.durations[firstSample...] { decodeTime = try add(decodeTime, UInt64(duration)) }
                    dataEnd = start + length
                }
                previousTrafEnd = dataEnd
            }
        }
        guard !track.chunks.isEmpty else { throw JoinError.malformed("no samples") }
        return track
    }

    /// The moov parts that are copied: mvhd, the single trak's headers and its sample description.
    private static func movieHeader(_ moov: Data) throws -> Track {
        let parts = try children(moov, 0..<moov.count)
        guard parts.contains(where: { $0.type == "mvex" }) else { throw JoinError.unsupported("not fragmented") }
        let traks = parts.filter { $0.type == "trak" }
        guard traks.count == 1 else { throw JoinError.unsupported("\(traks.count) tracks") }
        let mvhd = try one("mvhd", in: parts)
        let trak = try children(moov, traks[0].content..<traks[0].end)
        let tkhd = try one("tkhd", in: trak)
        let mdiaBox = try one("mdia", in: trak)
        let mdia = try children(moov, mdiaBox.content..<mdiaBox.end)
        let mdhd = try one("mdhd", in: mdia)
        let hdlr = try one("hdlr", in: mdia)
        let minfBox = try one("minf", in: mdia)
        let minf = try children(moov, minfBox.content..<minfBox.end)
        let stblBox = try one("stbl", in: minf)
        let stbl = try children(moov, stblBox.content..<stblBox.end)
        let stsd = try one("stsd", in: stbl)
        if let stsz = stbl.first(where: { $0.type == "stsz" }) {
            var reader = Reader(moov, stsz.content..<stsz.end)
            try reader.skip(8)
            guard try reader.u32() == 0 else { throw JoinError.unsupported("samples in the moov") }
        }
        var elst: (version: UInt8, entries: [(duration: UInt64, mediaTime: Int64, rate: UInt32)])?
        if let edts = trak.first(where: { $0.type == "edts" }),
           let list = try children(moov, edts.content..<edts.end).first(where: { $0.type == "elst" }) {
            var reader = Reader(moov, list.content..<list.end)
            let version = UInt8(try reader.uint(4) >> 24)
            let count = try reader.uint(4)
            let entrySize: UInt64 = version == 1 ? 20 : 12
            guard count <= UInt64(reader.end - reader.position) / entrySize else { throw JoinError.malformed("elst entry count") }
            var entries: [(duration: UInt64, mediaTime: Int64, rate: UInt32)] = []
            for _ in 0..<count {
                let duration = try reader.uint(version == 1 ? 8 : 4)
                let raw = try reader.uint(version == 1 ? 8 : 4)
                let mediaTime = version == 1 ? Int64(bitPattern: raw) : Int64(Int32(bitPattern: UInt32(raw)))
                entries.append((duration, mediaTime, try reader.u32()))
            }
            // A zero-length edit of media means "to the end" in a fragmented file; a regular MP4 cannot say that.
            guard !entries.contains(where: { $0.duration == 0 && $0.mediaTime >= 0 }) else { throw JoinError.unsupported("open-ended edit") }
            if !entries.isEmpty { elst = (version, entries) }
        }
        let mvhdData = Data(moov[mvhd.start..<mvhd.end]), mdhdData = Data(moov[mdhd.start..<mdhd.end])
        return Track(movieTimescale: try timescale(mvhdData), mediaTimescale: try timescale(mdhdData),
                     mvhd: mvhdData, tkhd: Data(moov[tkhd.start..<tkhd.end]), mdhd: mdhdData,
                     hdlr: Data(moov[hdlr.start..<hdlr.end]),
                     minfHeaders: minf.filter { $0.type != "stbl" }.map { Data(moov[$0.start..<$0.end]) },
                     stsd: Data(moov[stsd.start..<stsd.end]), elst: elst)
    }
    private static func defaults(_ moov: Data, trackID: UInt32) throws -> (trackID: UInt32, descriptionIndex: UInt32, duration: UInt32, size: UInt32, flags: UInt32) {
        let mvex = try one("mvex", in: try children(moov, 0..<moov.count))
        for trex in try children(moov, mvex.content..<mvex.end) where trex.type == "trex" {
            var reader = Reader(moov, trex.content..<trex.end)
            try reader.skip(4)
            guard try reader.u32() == trackID else { continue }
            return (trackID, try reader.u32(), try reader.u32(), try reader.u32(), try reader.u32())
        }
        throw JoinError.malformed("no trex for the track")
    }
    private static func children(_ data: Data, _ range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var position = range.lowerBound
        while position < range.upperBound {
            var reader = Reader(data, position..<range.upperBound)
            var length = try reader.uint(4)
            try reader.skip(4)
            let type = String(decoding: data[position + 4..<position + 8], as: UTF8.self)
            if length == 1 { length = try reader.uint(8) } else if length == 0 { length = UInt64(range.upperBound - position) }
            let headerLength = reader.position - position
            guard length >= UInt64(headerLength), length <= UInt64(range.upperBound - position) else { throw JoinError.malformed("\(type) box is cut off") }
            result.append(Box(type: type, start: position, content: position + headerLength, end: position + Int(length)))
            position += Int(length)
        }
        return result
    }
    private static func one(_ type: String, in boxes: [Box]) throws -> Box {
        let matches = boxes.filter { $0.type == type }
        guard matches.count == 1 else { throw JoinError.malformed("expected one \(type)") }
        return matches[0]
    }
    /// The timescale of an mvhd or mdhd box (header included).
    private static func timescale(_ header: Data) throws -> UInt32 {
        var reader = Reader(header, 8..<header.count)
        let version = try reader.uint(4) >> 24
        try reader.skip(version == 1 ? 16 : 8)
        let value = try reader.u32()
        guard value > 0 else { throw JoinError.malformed("zero timescale") }
        return value
    }
    private static func trackID(_ tkhd: Data) throws -> UInt32 {
        var reader = Reader(tkhd, 8..<tkhd.count)
        let version = try reader.uint(4) >> 24
        try reader.skip(version == 1 ? 16 : 8)
        return try reader.u32()
    }

    // MARK: - Output

    private static func movie(_ tracks: [Track], movieTimescale: UInt32, offsets: [[UInt64]], wide: Bool) throws -> Data {
        var traks = Data()
        var longest: UInt64 = 0
        for (index, track) in tracks.enumerated() {
            let mediaDuration = try track.durations.reduce(UInt64(0)) { try add($0, UInt64($1)) }
            var edts = Data()
            var trackDuration = try rescale(mediaDuration, from: track.mediaTimescale, to: movieTimescale)
            if let elst = track.elst {
                // Edit durations are in the input's movie timescale; media times stay in the media timescale.
                var body = be32(UInt32(elst.version) << 24) + be32(UInt32(elst.entries.count))
                trackDuration = 0
                for entry in elst.entries {
                    let duration = try rescale(entry.duration, from: track.movieTimescale, to: movieTimescale)
                    trackDuration = try add(trackDuration, duration)
                    if elst.version == 1 {
                        body += be64(duration) + be64(UInt64(bitPattern: entry.mediaTime))
                    } else {
                        guard duration <= UInt32.max else { throw JoinError.unsupported("edit too long") }
                        body += be32(UInt32(duration)) + be32(UInt32(bitPattern: Int32(truncatingIfNeeded: entry.mediaTime)))
                    }
                    body += be32(entry.rate)
                }
                edts = box("edts", box("elst", body))
            }
            longest = max(longest, trackDuration)
            var tkhd = track.tkhd
            let tkhdLong = tkhd.count > 8 && tkhd[8] == 1
            guard tkhd.count >= (tkhdLong ? 104 : 92) else { throw JoinError.malformed("tkhd is too short") }
            tkhd.replaceSubrange(8 + (tkhdLong ? 20 : 12)..<8 + (tkhdLong ? 24 : 16), with: be32(UInt32(index + 1)))
            try patch(&tkhd, at: 8 + (tkhdLong ? 28 : 20), long: tkhdLong, value: trackDuration)
            var mdhd = track.mdhd
            let mdhdLong = mdhd.count > 8 && mdhd[8] == 1
            guard mdhd.count >= (mdhdLong ? 44 : 32) else { throw JoinError.malformed("mdhd is too short") }
            try patch(&mdhd, at: 8 + (mdhdLong ? 24 : 16), long: mdhdLong, value: mediaDuration)
            let stbl = box("stbl", try track.stsd + sampleTables(track, offsets: offsets[index], wide: wide))
            let minf = box("minf", track.minfHeaders.reduce(Data(), +) + stbl)
            traks += box("trak", tkhd + edts + box("mdia", mdhd + track.hdlr + minf))
        }
        var mvhd = tracks[0].mvhd
        let mvhdLong = mvhd.count > 8 && mvhd[8] == 1
        guard mvhd.count >= (mvhdLong ? 120 : 108) else { throw JoinError.malformed("mvhd is too short") }
        try patch(&mvhd, at: 8 + (mvhdLong ? 24 : 16), long: mvhdLong, value: longest)
        let nextTrackID = 8 + (mvhdLong ? 108 : 96)
        mvhd.replaceSubrange(nextTrackID..<nextTrackID + 4, with: be32(3))
        return box("moov", mvhd + traks)
    }
    private static func sampleTables(_ track: Track, offsets: [UInt64], wide: Bool) throws -> Data {
        let count = UInt32(track.sizes.count)
        var stts = Data(), entries: UInt32 = 0
        for run in runs(track.durations) { stts += be32(run.count) + be32(run.value); entries += 1 }
        var tables = box("stts", be32(0) + be32(entries) + stts)
        if track.compositionOffsets.contains(where: { $0 != 0 }) {
            let signed = track.compositionOffsets.contains { $0 < 0 }
            var ctts = Data(); entries = 0
            for run in runs(track.compositionOffsets) {
                if signed {
                    guard let value = Int32(exactly: run.value) else { throw JoinError.unsupported("composition offset") }
                    ctts += be32(run.count) + be32(UInt32(bitPattern: value))
                } else {
                    guard let value = UInt32(exactly: run.value) else { throw JoinError.unsupported("composition offset") }
                    ctts += be32(run.count) + be32(value)
                }
                entries += 1
            }
            tables += box("ctts", be32(signed ? 1 << 24 : 0) + be32(entries) + ctts)
        }
        if track.sync.contains(false) {
            let sync = track.sync.indices.filter { track.sync[$0] }
            tables += box("stss", be32(0) + be32(UInt32(sync.count)) + sync.reduce(into: Data()) { $0 += be32(UInt32($1 + 1)) })
        }
        var stsc = Data(); entries = 0
        var chunkIndex: UInt32 = 1
        for run in runs(track.chunks.map { UInt32($0.samples) }) {
            stsc += be32(chunkIndex) + be32(run.value) + be32(1)
            chunkIndex += run.count; entries += 1
        }
        tables += box("stsc", be32(0) + be32(entries) + stsc)
        tables += box("stsz", be32(0) + be32(0) + be32(count) + track.sizes.reduce(into: Data()) { $0 += be32($1) })
        let chunkOffsets = offsets.reduce(into: Data()) { $0 += wide ? be64($1) : be32(UInt32(truncatingIfNeeded: $1)) }
        tables += box(wide ? "co64" : "stco", be32(0) + be32(UInt32(offsets.count)) + chunkOffsets)
        return tables
    }
    private static func runs<Value: Equatable>(_ values: [Value]) -> [(count: UInt32, value: Value)] {
        var result: [(count: UInt32, value: Value)] = []
        for value in values {
            if let last = result.last, last.value == value { result[result.count - 1].count += 1 }
            else { result.append((1, value)) }
        }
        return result
    }
    private static func patch(_ data: inout Data, at place: Int, long: Bool, value: UInt64) throws {
        if long { data.replaceSubrange(place..<place + 8, with: be64(value)); return }
        guard value <= UInt32.max else { throw JoinError.unsupported("duration does not fit a version 0 header") }
        data.replaceSubrange(place..<place + 4, with: be32(UInt32(value)))
    }
    private static func rescale(_ value: UInt64, from: UInt32, to: UInt32) throws -> UInt64 {
        if from == to { return value }
        let (product, overflow) = value.multipliedReportingOverflow(by: UInt64(to))
        guard !overflow else { throw JoinError.unsupported("duration overflow") }
        return try add(product, UInt64(from / 2)) / UInt64(from)
    }
    private static func add(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw JoinError.malformed("size overflow") }
        return sum
    }
    private static func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }
    private static func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
