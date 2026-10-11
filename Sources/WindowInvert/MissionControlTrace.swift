import AppKit
import QuartzCore

/// Opt-in geometry trace, sampled independently of the display link. No images, titles or input.
final class MissionControlTrace {
    private let targets: [CGWindowID: CGWindowID]
    private let queue = DispatchQueue(label: "WindowInvert.missionControlTrace")
    private let lock = NSLock()
    private var trackingTicks = 0
    private var lastTrackingTick: CFTimeInterval?
    private var detectedOverview: Bool?
    private var spacesStripVisible: Bool?
    private var activeTargets: [CGWindowID] = []
    private var timer: DispatchSourceTimer?
    private var samples: [[String: Any]] = []
    private let startTime = CACurrentMediaTime()
    private var metadata: [String: Any]

    init(targets: [CGWindowID: CGWindowID], hidesInMissionControl: Bool) {
        self.targets = targets
        metadata = [
            "formatVersion": 2,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "hidesInMissionControl": hidesInMissionControl,
            "targets": targets.map { ["target": $0.key, "overlay": $0.value] },
            "screens": NSScreen.screens.map { ["frame": Self.rect($0.frame), "scale": $0.backingScaleFactor] },
            "rectFormat": "[x,y,width,height]; window coordinates are Core Graphics, screens are AppKit",
            "transformFormat": "[a,b,c,d,tx,ty]; raw SLSGetWindowTransform (not assumed to be presentation geometry)",
        ]
    }

    func recordTrackingTick(missionControl: MissionControlState, activeTargets: [CGWindowID]) {
        lock.lock()
        trackingTicks += 1
        lastTrackingTick = CACurrentMediaTime() - startTime
        detectedOverview = missionControl.overviewVisible
        spacesStripVisible = missionControl.spacesStripVisible
        self.activeTargets = activeTargets
        lock.unlock()
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if CACurrentMediaTime() - self.startTime >= 20 {
                self.finish(completion: completion)
            } else {
                self.sample()
            }
        }
        timer.resume()
    }

    private func sample() {
        let time = CACurrentMediaTime() - startTime
        lock.lock()
        var sample: [String: Any] = ["time": time, "trackingTicks": trackingTicks,
                                     "lastTrackingTick": lastTrackingTick as Any? ?? NSNull(),
                                     "overviewSurfaceVisible": detectedOverview as Any? ?? NSNull(),
                                     "spacesStripVisible": spacesStripVisible as Any? ?? NSNull(),
                                     "activeTargets": activeTargets]
        lock.unlock()
        var owners: [pid_t: String] = [:]
        for bundle in ["com.apple.dock", "com.apple.WindowManager"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                owners[app.processIdentifier] = bundle
            }
        }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        sample["windowListAvailable"] = windows != nil
        sample["compositorOwners"] = owners.map { ["pid": $0.key, "bundleID": $0.value] as [String: Any] }
        sample["windows"] = (windows ?? []).compactMap { info -> [String: Any]? in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let role: String
            if targets[id] != nil { role = "target" }
            else if targets.values.contains(id) { role = "overlay" }
            else if let owner = owners[pid] { role = owner }
            else { return nil }
            return Self.windowRecord(info: info, role: role, nativeBounds: WindowServer.bounds(of: id),
                                     transform: WindowServer.transform(of: id), orderedIn: WindowServer.orderedIn(id))
        }
        sample["readDuration"] = CACurrentMediaTime() - startTime - time
        samples.append(sample)
    }

    static func windowRecord(info: [String: Any], role: String, nativeBounds: CGRect?,
                             transform: CGAffineTransform?, orderedIn: Bool?) -> [String: Any] {
        let publicBounds = (info[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) }
        var result: [String: Any] = ["role": role, "publicBounds": rect(publicBounds),
                                     "nativeBounds": rect(nativeBounds), "orderedIn": orderedIn as Any? ?? NSNull()]
        for (key, source) in [("id", kCGWindowNumber), ("pid", kCGWindowOwnerPID), ("layer", kCGWindowLayer),
                              ("onScreen", kCGWindowIsOnscreen), ("alpha", kCGWindowAlpha)] {
            result[key] = info[source as String] as? NSNumber ?? NSNull()
        }
        let values = transform.map { [$0.a, $0.b, $0.c, $0.d, $0.tx, $0.ty] }
        result["transform"] = values.flatMap { $0.allSatisfy(\.isFinite) ? $0 : nil } as Any? ?? NSNull()
        return result
    }

    private static func rect(_ value: CGRect?) -> Any {
        guard let value, !value.isNull, !value.isInfinite else { return NSNull() }
        let values = [value.minX, value.minY, value.width, value.height]
        return values.allSatisfy(\.isFinite) ? values as Any : NSNull()
    }

    private func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        timer?.cancel()
        timer = nil
        metadata["samples"] = samples
        let result: Result<URL, Error> = Result {
            let directory = Log.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("WindowInvert-MissionControl-\(Int(Date().timeIntervalSince1970)).json")
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
            return url
        }
        DispatchQueue.main.async { completion(result) }
    }
}
