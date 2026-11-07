#if DEBUG
import AVFoundation
import Foundation

/// Reads container JSON and media timing headers only. Never decodes images or
/// audio samples, opens capture devices, or modifies drafts/Photos.
@MainActor enum DraftTimingDiagnostics {
    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        var report: [String: Any] = [
            "runIdentifier": environment["ROAST_DIAGNOSTIC_RUN_ID"] ?? UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "metadataOnly": true, "imagesDecoded": false, "audioDecoded": false,
            "cameraEnabled": false, "microphoneEnabled": false, "phase": "starting",
        ]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let destination = caches.appendingPathComponent("EditorDraftTimingDiagnostic.json")
        func write() {
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: destination, options: .atomic)
        }
        func number(_ value: Double) -> Any { value.isFinite ? value : NSNull() }
        write()
        do {
            guard let rawID = environment["ROAST_DRAFT_TIMING_ID"], let id = UUID(uuidString: rawID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Drafts").appendingPathComponent(id.uuidString)
            let draft = try JSONDecoder().decode(RecordingDraft.self,
                from: Data(contentsOf: folder.appendingPathComponent("draft.json")))
            let edits = try JSONDecoder().decode(TakeEdits.self,
                from: Data(contentsOf: folder.appendingPathComponent("edits.json")))
            report["draftID"] = id.uuidString
            report["draftDuration"] = number(draft.duration)
            report["trimStart"] = number(edits.trimStart)
            report["trimEnd"] = number(edits.trimEnd)
            report["cuts"] = edits.cuts.map { ["start": number($0.start), "end": number($0.end)] }
            report["unboundedTimelineDuration"] = number(EditorTimeline(duration: draft.duration, edits: edits).duration)
            report["phase"] = "readingTimingHeaders"
            write()
            let captureURL = folder.appendingPathComponent(draft.videoURL.lastPathComponent)
            let capture = AVURLAsset(url: captureURL)
            defer { withExtendedLifetime(capture) {} }
            report["captureAssetDuration"] = number(try await capture.load(.duration).seconds)
            var tracks: [[String: Any]] = []
            for mediaType in [AVMediaType.video, .audio] {
                for track in try await capture.loadTracks(withMediaType: mediaType) {
                    let range = try await track.load(.timeRange)
                    tracks.append(["mediaType": mediaType.rawValue, "trackID": track.trackID,
                                   "start": number(range.start.seconds), "duration": number(range.duration.seconds),
                                   "end": number(range.end.seconds)])
                    if mediaType == .video {
                        let boundedDuration = min(draft.duration, range.end.seconds)
                        var bounded = edits
                        bounded.trimStart = max(edits.trimStart, range.start.seconds)
                        let timeline = EditorTimeline(duration: boundedDuration, edits: bounded)
                        report["exportBoundedDuration"] = number(boundedDuration)
                        report["exportBoundedTrimStart"] = number(bounded.trimStart)
                        report["exportTimelineDuration"] = number(timeline.duration)
                        report["exportSegments"] = timeline.segments.map {
                            ["sourceStart": number($0.sourceStart), "sourceEnd": number($0.sourceEnd),
                             "outputStart": number($0.outputStart)]
                        }
                    }
                }
            }
            report["captureTracks"] = tracks
            if let source = draft.sourceAudioURL {
                let asset = AVURLAsset(url: folder.appendingPathComponent(source.lastPathComponent))
                defer { withExtendedLifetime(asset) {} }
                report["sourceAssetDuration"] = number(try await asset.load(.duration).seconds)
                report["sourceAudioRanges"] = try await asset.loadTracks(withMediaType: .audio).asyncMap { track in
                    let range = try await track.load(.timeRange)
                    return ["start": number(range.start.seconds), "duration": number(range.duration.seconds),
                            "end": number(range.end.seconds)]
                }
            }
            if environment["ROAST_DRAFT_TIMING_BUILD_COMPOSITION"] == "1" {
                report["phase"] = "buildingProductionComposition"
                write()
                let rebased = RecordingDraft(id: draft.id, videoURL: captureURL,
                    microphoneURL: draft.microphoneURL.map { folder.appendingPathComponent($0.lastPathComponent) },
                    sourceAudioURL: draft.sourceAudioURL.map { folder.appendingPathComponent($0.lastPathComponent) },
                    duration: draft.duration, title: draft.title)
                do {
                    let composed = try await EditorExporter.composition(draft: rebased, edits: edits)
                    defer { withExtendedLifetime(composed.retainedAssets) {} }
                    report["productionCompositionSucceeded"] = true
                    report["productionCompositionDuration"] = number(composed.timeline.duration)
                    report["productionAudioTrackCount"] = try await composed.asset.loadTracks(withMediaType: .audio).count
                    report["productionVideoTrackCount"] = try await composed.asset.loadTracks(withMediaType: .video).count
                } catch {
                    report["productionCompositionSucceeded"] = false
                    report["productionCompositionError"] = error.localizedDescription
                }
            }
            report["phase"] = "complete"
        } catch {
            report["phase"] = "failed"
            report["error"] = error.localizedDescription
        }
        write()
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for item in self { results.append(try await transform(item)) }
        return results
    }
}
#endif
