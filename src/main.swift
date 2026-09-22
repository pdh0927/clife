import Cocoa
import UserNotifications

// MARK: - Data

/// One row of the plan-usage breakdown, as returned by /api/oauth/usage.
///
/// The API's `limits` array is the same list Claude's own menu bar popup renders,
/// so mirroring it verbatim (rather than cherry-picking two known fields) means a
/// new row -- a per-model weekly cap, a surface-scoped cap -- shows up here the day
/// it shows up there, with no code change.
struct UsageLimit {
    let kind: String        // "session", "weekly_all", "weekly_scoped", ...
    let group: String       // "session" | "weekly"
    let percent: Double
    let resetsAt: Date?
    let scopeModel: String?   // e.g. "Fable", on weekly_scoped rows
    let scopeSurface: String? // e.g. a surface-scoped cap, when one is active

    /// Stable identity across refreshes, used to key notification state. `kind` alone
    /// collides as soon as two scoped rows exist, and so does kind+model if two scoped
    /// rows ever arrive without a model name -- then both would share one set of fired
    /// thresholds and one of them would go quiet. Key on the whole scope.
    var id: String {
        [kind, scopeModel, scopeSurface].compactMap { $0 }.joined(separator: ":")
    }

    var title: String {
        switch kind {
        case "session":       return "5시간 한도"
        case "weekly_all":    return "주간 · 모든 모델"
        case "weekly_scoped": return "주간 · \(scopeModel ?? "모델별")"
        default:              return scopeModel.map { "\(kind) · \($0)" } ?? kind
        }
    }
}

// MARK: - Response cache

/// The last successful response, on disk, shared with `raycast/claude-usage.py`.
///
/// Two jobs. First, the app can show real rings the instant it launches instead of a
/// "no data" question mark -- relaunching during a rate-limit cooldown otherwise means
/// staring at `?` until the block lifts, even though perfectly good numbers were on
/// screen a second earlier. Second, the app and the Raycast hotkey hit one shared rate
/// limit, so whichever fetched last covers the other for the next `freshFor` seconds.
///
/// The file's mtime is the fetch time; no timestamp is written into the payload.
enum UsageCache {
    /// How long a stored response stands in for a new request. Usage doesn't move
    /// meaningfully inside this window, and the endpoint is far too rate limited to
    /// spend a request re-confirming that.
    static let freshFor: TimeInterval = 30

    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/com.example.clife/usage.json")

    static func read() -> (data: Data, fetchedAt: Date)? {
        guard let data = try? Data(contentsOf: url),
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                                    .contentModificationDate
        else { return nil }
        return (data, modified)
    }

    /// Written to a temp file and moved into place, so a concurrent reader (the
    /// Raycast script, the other half of this pair) never sees a half-written file.
    static func write(_ data: Data) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("usage.json.tmp")
        guard (try? data.write(to: temporary)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}

// MARK: - API client

enum UsageAPI {
    struct Snapshot {
        let limits: [UsageLimit]
        /// When these numbers were fetched -- not when we handed them over, which is
        /// what makes a cache hit report its real age rather than claiming "just now".
        let fetchedAt: Date
    }

    enum Failure: Error {
        case noToken                            // never logged in, or the keychain item is gone
        case unauthorized                       // token expired; Claude Code refreshes it on next use
        case rateLimited(retryAfter: TimeInterval)
        case http(Int)
        case transport(Error)
        case malformed
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The endpoint is rate limited and answers 429 with a Retry-After measured in
    /// minutes, so this is not an endpoint to poll tightly. Used when a 429 arrives
    /// without a parseable Retry-After.
    static let defaultRetryAfter: TimeInterval = 300

    /// Reads Claude Code's OAuth token out of the login keychain by shelling out to
    /// /usr/bin/security, rather than calling SecItemCopyMatching from inside this app.
    ///
    /// The reason is the keychain ACL prompt: it is granted per *code signature*, and
    /// this app is ad-hoc signed, so its signature changes on every rebuild -- an
    /// in-process read would re-prompt after each `./build.sh`. Delegating to
    /// /usr/bin/security attributes the access to a stable Apple-signed binary, so a
    /// single "Always Allow" survives rebuilds.
    ///
    /// We only ever read the token. Refreshing it is deliberately left to Claude Code:
    /// writing a rotated token back would race with whatever Claude Code process is
    /// doing the same thing, and losing that race invalidates the refresh token for
    /// both of us.
    ///
    /// Spawning a process costs ~25ms, so the token is cached in memory until just
    /// before it expires (the keychain payload carries `expiresAt`). A rotation by
    /// Claude Code before that point would leave us on a stale token; the 401 path
    /// drops the cache, so the next attempt picks up the new one.
    private static var cachedToken: (value: String, expiresAt: Date)?
    private static let tokenLock = NSLock()

    static func invalidateToken() {
        tokenLock.lock(); cachedToken = nil; tokenLock.unlock()
    }

    private static func accessToken() throws -> String {
        tokenLock.lock()
        defer { tokenLock.unlock() }

        // 60s of slack so a token that expires mid-request doesn't come back 401.
        if let cached = cachedToken, cached.expiresAt.timeIntervalSinceNow > 60 {
            return cached.value
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { throw Failure.transport(error) }

        // `security` blocks indefinitely if the keychain is locked or an approval
        // dialog is waiting somewhere the user can't see it (behind a fullscreen
        // window, say). Without this the read never returns, and every later refresh
        // queues behind it forever.
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: killer)
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()

        guard proc.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw Failure.noToken }

        // expiresAt is epoch milliseconds. Absent/garbage means "don't cache",
        // which just costs us the process spawn again next time.
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        cachedToken = expiresAt.map { (token, $0) }
        return token
    }

    /// `2026-09-20T09:10:00.606234+00:00` -- six fractional digits, which
    /// ISO8601DateFormatter does not reliably accept. Drop the fraction (we render
    /// whole minutes at best) and parse the rest, which is plain RFC 3339.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
            text = String(text[text.startIndex..<dot]) + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func decode(_ data: Data) throws -> [UsageLimit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["limits"] as? [[String: Any]]
        else { throw Failure.malformed }

        return rows.compactMap { row in
            guard let kind = row["kind"] as? String,
                  let percent = row["percent"] as? Double
            else { return nil }
            let scope = row["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            return UsageLimit(
                kind: kind,
                group: row["group"] as? String ?? kind,
                percent: percent,
                resetsAt: parseDate(row["resets_at"] as? String),
                scopeModel: model?["display_name"] as? String,
                scopeSurface: scope?["surface"] as? String
            )
        }
    }

    /// A private session rather than `URLSession.shared`.
    ///
    /// `shared` carries a disk-backed HTTP cache plus process-wide cookie and
    /// credential storage, and this app has exactly one request whose entire value is
    /// being current. A response served from an HTTP cache would look identical to a
    /// fresh one while being silently wrong -- the same class of bug that made the old
    /// statusline version untrustworthy. Ephemeral keeps nothing on disk, and the
    /// explicit policy means freshness does not hinge on the server remembering to
    /// send `no-store`.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        // One request at a time by design; more would only spend the rate limit faster.
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The stored response, however old, for seeding the UI at launch.
    static func cachedSnapshot() -> Snapshot? {
        guard let (data, fetchedAt) = UsageCache.read(), let limits = try? decode(data) else { return nil }
        return Snapshot(limits: limits, fetchedAt: fetchedAt)
    }

    /// `allowCache` is false when a person is waiting on the answer: a cached reading
    /// is by definition not the current one, and "current when looked at" is the whole
    /// job. The background timer passes true, because a response the Raycast hotkey
    /// fetched moments ago answers its question perfectly well -- and the two share one
    /// rate limit, so re-asking would only take a slot away from the next real look.
    static func fetch(allowCache: Bool = true, completion: @escaping (Result<Snapshot, Failure>) -> Void) {
        let finish: (Result<Snapshot, Failure>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        if allowCache, let snapshot = cachedSnapshot(),
           snapshot.fetchedAt.timeIntervalSinceNow > -UsageCache.freshFor {
            finish(.success(snapshot))
            return
        }

        // The keychain read can block (on a prompt, or a locked keychain), so it must
        // not run on the main queue -- a blocked main queue freezes the menu bar item.
        DispatchQueue.global(qos: .utility).async {
            let token: String
            do { token = try accessToken() } catch { finish(.failure(error as? Failure ?? .noToken)); return }

            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15

            session.dataTask(with: request) { data, response, error in
                if let error { finish(.failure(.transport(error))); return }
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if code == 401 || code == 403 {
                    // The cached token is the likely culprit; force a keychain re-read
                    // next time, in case Claude Code has already rotated it.
                    invalidateToken()
                    finish(.failure(.unauthorized))
                    return
                }
                if code == 429 {
                    let header = http?.value(forHTTPHeaderField: "Retry-After")
                    let seconds = header.flatMap(TimeInterval.init) ?? defaultRetryAfter
                    finish(.failure(.rateLimited(retryAfter: max(seconds, 30))))
                    return
                }
                guard code == 200, let data else { finish(.failure(.http(code))); return }
                do {
                    let limits = try decode(data)
                    UsageCache.write(data)
                    finish(.success(Snapshot(limits: limits, fetchedAt: Date())))
                } catch { finish(.failure(.malformed)) }
            }.resume()
        }
    }
}

// MARK: - Icon rendering

/// Draws the menu bar icon in code (Core Graphics via NSBezierPath) so it can be
/// regenerated on every data refresh instead of shipping static image assets.
enum IconFactory {
    private static let canvas = NSSize(width: 20, height: 20)
    private static let outerRadius: CGFloat = 8.4   // session usage
    private static let innerRadius: CGFloat = 4.6   // weekly usage
    private static let lineWidth: CGFloat = 2.0

    static func color(for pct: Double) -> NSColor {
        if pct >= 90 { return .systemRed }
        if pct >= 70 { return .systemYellow }
        return .systemGreen
    }

    private static func trackPath(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                     width: radius * 2, height: radius * 2))
    }

    /// Progress arc starting at 12 o'clock, sweeping clockwise proportional to pct.
    private static func progressPath(center: NSPoint, radius: CGFloat, pct: Double) -> NSBezierPath {
        let clamped = max(0, min(100, pct))
        let path = NSBezierPath()
        guard clamped > 0 else { return path }
        let end: CGFloat = 90 - 360 * CGFloat(clamped / 100)
        path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: end, clockwise: true)
        return path
    }

    /// Outer ring = current session usage, inner ring = weekly usage.
    /// Colored (not template) so the green/yellow/red threshold is visible without
    /// reading numbers -- see README "Design notes" for the template-vs-color tradeoff.
    ///
    /// `stale` drains the color out of both arcs. The whole point of the ring is that
    /// it can be judged at a glance, without opening anything -- so numbers that have
    /// stopped being current must not keep presenting themselves in confident green.
    /// Greying them says "this is the last thing I knew" in the one place the user is
    /// actually looking; the dropdown says why.
    static func dualRingIcon(session: Double, week: Double, stale: Bool = false) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)

            NSColor.tertiaryLabelColor.setStroke()
            for radius in [outerRadius, innerRadius] {
                let track = trackPath(center: center, radius: radius)
                track.lineWidth = lineWidth
                track.stroke()
            }

            let outer = progressPath(center: center, radius: outerRadius, pct: session)
            outer.lineWidth = lineWidth
            outer.lineCapStyle = .round
            (stale ? NSColor.secondaryLabelColor : color(for: session)).setStroke()
            outer.stroke()

            let inner = progressPath(center: center, radius: innerRadius, pct: week)
            inner.lineWidth = lineWidth
            inner.lineCapStyle = .round
            (stale ? NSColor.secondaryLabelColor : color(for: week)).setStroke()
            inner.stroke()

            return true
        }
        image.isTemplate = false
        return image
    }

    /// Shown when usage could not be fetched at all -- distinct from a real 0% ring
    /// so "no data" is never mistaken for "no usage".
    static func unknownIcon() -> NSImage {
        let base = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "사용량 정보 없음")
            ?? NSImage(size: canvas)
        let configured = base.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? base
        configured.isTemplate = true
        return configured
    }
}

// MARK: - Refresh trigger

/// What caused a refresh attempt. Kept because the throttle differs by origin: a
/// pointer drifting through the menu bar is a weaker signal of intent than opening
/// the dropdown, and gets a longer floor.
enum RefreshTrigger: String {
    case launch, menuBar, menuOpen, manual, timer, wake

}

// MARK: - Display mode

/// User-chosen menu bar presentation, persisted across launches.
enum DisplayMode: String {
    case icon   // dual-ring gauge (default)
    case text   // "54%/29%", the original text-only presentation
}

// MARK: - Dropdown row view

/// A labeled progress bar + reset-time subtitle, used as a menu item's custom view
/// in place of a plain text row -- so usage is scannable as a bar, not just a number.
final class UsageRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var fillWidthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 54))

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percentLabel.alignment = .right

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.3).cgColor
        track.layer?.cornerRadius = 3
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3

        for v in [titleLabel, percentLabel, subtitleLabel, track] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            percentLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            track.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            track.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            track.heightAnchor.constraint(equalToConstant: 6),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, percent: Double?, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle

        fillWidthConstraint?.isActive = false
        guard let percent else {
            percentLabel.stringValue = "-"
            fill.layer?.backgroundColor = NSColor.clear.cgColor
            pawPercent = nil
            needsDisplay = true
            return
        }
        percentLabel.stringValue = String(format: "%.0f%%", percent)
        fill.layer?.backgroundColor = IconFactory.color(for: percent).cgColor

        let fraction = CGFloat(max(0, min(100, percent)) / 100)
        let constraint = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: fraction)
        constraint.isActive = true
        fillWidthConstraint = constraint

        pawPercent = percent
        needsDisplay = true
    }

    /// Where this limit has got to, marked with a paw print on the track.
    ///
    /// Only the header carries a whole dog. Four dogs in one menu would make the
    /// reader pick which one to believe, which is the opposite of a glanceable
    /// display -- but a paw still ties each bar to the same character, so the rows
    /// read as the same run rather than as unrelated meters.
    private var pawPercent: Double?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pawPercent else { return }
        let fraction = CGFloat(max(0, min(100, pawPercent)) / 100)
        let trackFrame = track.frame
        let size: CGFloat = 13
        let x = trackFrame.minX + trackFrame.width * fraction - size / 2
        let rect = NSRect(x: x, y: trackFrame.midY - size / 2, width: size, height: size)
        IconFactory.color(for: pawPercent).setFill()
        DogArt.pawPath(in: rect).fill()
    }
}

// MARK: - Dropdown header

/// The dog and what it has to say, above the numbers.
///
/// The rows answer "how much", which is only ever half of what someone opens this
/// for. The other half -- "is that fine?" -- is a judgement they otherwise have to
/// make themselves every time, from three percentages with different windows and
/// different limits. The dog makes that judgement once, out loud, about whichever
/// limit is closest to stopping them.
final class DogHeaderView: NSView {
    private let sayLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private var mood: DogMood = .energetic
    private var hasData = false

    /// Stride position, 0..<1. Advanced by a timer that exists only while the dog is
    /// actually on screen -- a shut menu and a hidden widget are both reasons to draw
    /// nothing at all, and this app is otherwise at 0% CPU when idle.
    private var frameIndex = 0
    private var animation: Timer?
    private static let frameInterval: TimeInterval = 1.0 / 12

    private static let dogWidth: CGFloat = 62
    private static let bubbleInset: CGFloat = 11

    /// The only part of this view that moves. Invalidating the whole view every frame
    /// would redraw the bubble and ask both text fields to lay out and render again --
    /// measured at 3.6% CPU for one small dog, which is not a price a glanceable
    /// widget should charge for being pretty.
    private var dogRect: NSRect {
        NSRect(x: 12, y: 6, width: Self.dogWidth, height: bounds.height - 12)
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 68))
        sayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor

        for v in [sayLabel, subLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.lineBreakMode = .byTruncatingTail
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            sayLabel.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: 14 + Self.dogWidth + Self.bubbleInset),
            sayLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            sayLabel.topAnchor.constraint(equalTo: topAnchor, constant: 17),

            subLabel.leadingAnchor.constraint(equalTo: sayLabel.leadingAnchor),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            subLabel.topAnchor.constraint(equalTo: sayLabel.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `limit` is the one the dog speaks for -- the tightest, not the first.
    func update(limit: UsageLimit?, reset: String) {
        guard let limit else {
            hasData = false
            sayLabel.stringValue = "아직 모르겠어요"
            subLabel.stringValue = "사용량을 불러오는 중"
            needsDisplay = true
            return
        }
        hasData = true
        let previous = mood
        mood = DogMood(percent: limit.percent)
        if mood != previous, animation != nil {
            // Cadence is per mood, so the timer has to be rebuilt when the mood moves.
            stopAnimating()
            startAnimating()
        }
        sayLabel.stringValue = mood.line
        // Just which limit and how far along. The reset time is on that limit's own
        // row a few points below, and repeating it here only bought a truncated line.
        _ = reset
        subLabel.stringValue = String(format: "%@ · %.0f%%", limit.title, limit.percent)
        needsDisplay = true
    }

    private func drawDog() {
        let rect = dogRect
        let frames = DogArt.frames(mood: hasData ? mood : .steady, size: rect.size)
        let image = frames[min(frameIndex, frames.count - 1)]
        // Inset so the tilt and bounce below stay inside the rect that gets
        // invalidated each frame -- otherwise the corners clip as it leans.
        let target = DogHeaderView.fit(image.size, into: rect.insetBy(dx: 4, dy: 4))

        // Supplied art gets a bounce and a tilt laid over it.
        //
        // The frames that came back from image generation have almost no stride in
        // them -- the paws travel 10px across a 263px canvas, under 4% -- so played
        // back on their own the dog just hovers. Motion that is not in the frames
        // cannot be recovered from them, but a body that rises, falls and leans is
        // what reads as running at this size anyway, and that part is arithmetic.
        // Real leg swing still needs frames that actually contain it.
        guard DogArt.usesSuppliedArt, DogArt.strideDuration(mood) > 0, frames.count > 1 else {
            image.draw(in: target)
            return
        }

        let phase = CGFloat(frameIndex) / CGFloat(frames.count)
        let bounce = sin(phase * 2 * .pi)          // one rise and fall per stride
        let lean = sin(phase * 2 * .pi + .pi / 2)  // leans into the rise, a quarter ahead

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: target.midX, yBy: target.minY + target.height * 0.22)
        transform.rotate(byDegrees: lean * 3.0)
        transform.translateX(by: -target.midX, yBy: -(target.minY + target.height * 0.22))
        transform.translateX(by: 0, yBy: bounce * 2.2)
        transform.concat()
        image.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Largest rect of `size`'s aspect ratio that fits inside `rect`, centred.
    ///
    /// `NSImage.draw(in:)` stretches to fill, which squashes supplied art — the frames
    /// are portrait and the space for them is landscape. The drawn fallback is
    /// generated at exactly the requested size, so this is a no-op there and only
    /// matters once image files are in play.
    static func fit(_ size: NSSize, into rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                      width: drawn.width, height: drawn.height)
    }

    /// Flipped by the menu toggle. Static because both the menu's header and the
    /// widget's answer to the same setting, and threading it through two owners to
    /// say one thing would be ceremony.
    static var animationEnabled = true {
        didSet { NotificationCenter.default.post(name: DogHeaderView.enabledChanged, object: nil) }
    }
    static let enabledChanged = Notification.Name("DogHeaderViewAnimationEnabledChanged")

    func startAnimating() {
        guard animation == nil, Self.animationEnabled else { return }
        // A stride of zero means this pose does not run -- the dog has sat down. No
        // timer at all is the honest way to say that, and it costs nothing.
        guard DogArt.strideDuration(mood) > 0 else { frameIndex = 0; needsDisplay = true; return }
        // Interval comes from how long the whole stride should take, so a tired dog
        // genuinely runs slower rather than just looking different.
        // Capped: past about 12fps the extra frames cost battery without reading as
        // any smoother at this size, and the whole point of a desktop widget is that
        // you can leave it on.
        let interval = max(DogArt.strideDuration(mood) / Double(DogArt.frameCount), 1.0 / 12)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % DogArt.frameCount
            self.setNeedsDisplay(self.dogRect)
        }
        // A menu runs a modal run loop while open; without .common the dog would
        // freeze at exactly the moment someone is looking at it.
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    func stopAnimating() {
        animation?.invalidate()
        animation = nil
    }

    deinit { animation?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // A frame tick dirties only the dog, and the bubble does not intersect it --
        // so on those passes there is nothing else to paint.
        guard dirtyRect.intersects(bounds.divided(atDistance: 12 + Self.dogWidth,
                                                  from: .minXEdge).remainder) else {
            drawDog()
            return
        }

        // Speech bubble behind the text, tinted by mood so the colour agrees with
        // the words instead of being decoration.
        let bubbleX = 14 + Self.dogWidth + 3
        let bubble = NSRect(x: bubbleX, y: 8, width: bounds.width - bubbleX - 10, height: bounds.height - 16)
        let tint = hasData ? mood.tint : NSColor.secondaryLabelColor
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 11, yRadius: 11).fill()

        // Tail of the bubble, pointing back at whoever is talking.
        let notch = NSBezierPath()
        notch.move(to: CGPoint(x: bubble.minX + 0.5, y: bubble.midY + 6))
        notch.line(to: CGPoint(x: bubble.minX - 5, y: bubble.midY))
        notch.line(to: CGPoint(x: bubble.minX + 0.5, y: bubble.midY - 6))
        notch.close()
        notch.fill()

        drawDog()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let displayModeDefaultsKey = "displayMode"
    private static let runningDefaultsKey = "dogRunning"

    /// Background cadence -- and deliberately slow, because the background poll is the
    /// least valuable request the app makes.
    ///
    /// Everything competes for one tight budget: two calls 16 seconds apart already
    /// draw a 429. Spending that budget on ticks nobody is looking at means the tick
    /// that matters -- the one fired because a human just moved the pointer to the
    /// menu bar -- is the one that gets refused. So the background exists only to keep
    /// the threshold notifications alive; being current when someone actually looks is
    /// the on-demand triggers' job, and they get the headroom.
    private static let pollInterval: TimeInterval = 600

    /// Floor between on-demand refreshes. Purely anti-spam -- a pointer wandering in
    /// and out of the menu bar can cross the band several times a second, and that is
    /// mouse travel, not someone asking a question. It is deliberately short enough to
    /// be imperceptible: any real look is more than five seconds apart, so in practice
    /// looking at the rings always fetches.
    private static let onDemandMinInterval: TimeInterval = 5

    /// Longer floor for the hover trigger specifically. Opening the dropdown or
    /// pressing the hotkey is an unmistakable request for a number; drifting through
    /// the menu bar is not, and it happens many times an hour on the way to somewhere
    /// else. Fifteen seconds is still far below the interval between two real looks at
    /// a ring, so it costs nothing a person would notice, and it keeps a pointer that
    /// wanders in and out from spending the whole rate limit on travel.
    private static let hoverMinInterval: TimeInterval = 15

    /// How many times to re-check whether the bar came down, `hoverDwell` apart. Seven
    /// covers about two seconds, which is generous next to any reveal animation and
    /// still short enough that a pointer resting near the top of a fullscreen window
    /// gives up quietly rather than watching forever.
    private static let hoverCheckAttempts = 7

    /// How long the pointer must stay in the menu bar before prefetching. Enough to
    /// ignore a cursor flung through the top edge on its way somewhere else; short
    /// enough that a ~0.3s request lands while the user is still looking.
    private static let hoverDwell: TimeInterval = 0.3

    /// Comfortably past the request's own 15s timeout plus the keychain read, so this
    /// only fires when something is genuinely stuck rather than merely slow.
    private static let fetchWatchdog: TimeInterval = 30

    /// Rows are built from whatever the API returns, so the count is not fixed. The
    /// response already carries placeholders for more kinds than are currently active
    /// (per-model, per-surface), and a limit that exists but isn't shown is worse than
    /// a slightly taller menu -- the whole point is not to be surprised by a cap.
    /// Anything beyond this still reaches the tooltip.
    private static let maxRows = 6

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var dogHeader: DogHeaderView!
    private let desktopWidget = DesktopWidget()
    private var rowViews: [UsageRowView] = []
    private var rowItems: [NSMenuItem] = []
    private var statusMenuItem: NSMenuItem!
    private var widgetItem: NSMenuItem!
    private var runningItem: NSMenuItem!
    private var iconModeMenuItem: NSMenuItem!
    private var textModeMenuItem: NSMenuItem!
    private var pollTimer: Timer?
    private var stalenessTimer: Timer?
    private var hoverWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var pointerInMenuBar = false

    // Defaults to .icon; overridden below if a valid choice was saved before.
    private var displayMode: DisplayMode = .icon

    // Last successful snapshot. Kept so switching display mode redraws immediately,
    // and so a transient network failure shows the last real numbers (flagged stale
    // in the status line) instead of blanking to "-".
    private var limits: [UsageLimit] = []
    private var lastSuccess: Date?
    private var lastAttempt: Date?
    private var lastFailure: UsageAPI.Failure?
    private var inFlight = false

    /// Earliest time a request is allowed again. Set from a 429's Retry-After, or
    /// from exponential backoff after a transport/server error, so a failing endpoint
    /// isn't hammered at the poll cadence.
    private var blockedUntil: Date?
    private var consecutiveFailures = 0

    // Desktop-notification thresholds. Each fires at most once per window;
    // state for a row resets whenever that row's resets_at changes (i.e. a new
    // window started), so the same crossing can notify again next window.
    private static let notifyThresholds: [Double] = [30, 50, 60, 70, 80, 90, 95]
    private var firedThresholds: [String: Set<Double>] = [:]
    private var knownResets: [String: Date?] = [:]
    private var hasSeenFirstLoad = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if let saved = UserDefaults.standard.string(forKey: Self.displayModeDefaultsKey),
           let mode = DisplayMode(rawValue: saved) {
            displayMode = mode
        }

        let menu = NSMenu()
        menu.delegate = self

        dogHeader = DogHeaderView()
        let headerItem = NSMenuItem()
        headerItem.view = dogHeader
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        for _ in 0..<Self.maxRows {
            let view = UsageRowView()
            let item = NSMenuItem()
            item.view = view
            item.isHidden = true
            menu.addItem(item)
            rowViews.append(view)
            rowItems.append(item)
        }

        statusMenuItem = Self.headerMenuItem("불러오는 중...")
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(Self.headerMenuItem("표시 방식"))
        iconModeMenuItem = NSMenuItem(title: "아이콘으로 보기", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
        iconModeMenuItem.target = self
        iconModeMenuItem.tag = 0
        textModeMenuItem = NSMenuItem(title: "숫자로 보기", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
        textModeMenuItem.target = self
        textModeMenuItem.tag = 1
        menu.addItem(iconModeMenuItem)
        menu.addItem(textModeMenuItem)
        updateModeMenuState()

        menu.addItem(NSMenuItem.separator())
        runningItem = NSMenuItem(title: "강아지 달리기", action: #selector(toggleRunning), keyEquivalent: "")
        runningItem.target = self
        runningItem.state = dogRunning ? .on : .off
        menu.addItem(runningItem)

        widgetItem = NSMenuItem(title: "바탕화면 위젯", action: #selector(toggleWidget), keyEquivalent: "")
        widgetItem.target = self
        menu.addItem(widgetItem)

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "새로 고침", action: #selector(refresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Show the last known numbers before the first request even goes out. Without
        // this, launching during a rate-limit cooldown means a "no data" question mark
        // until the block lifts, discarding numbers that were on screen a second ago.
        if let snapshot = UsageAPI.cachedSnapshot() {
            limits = snapshot.limits
            lastSuccess = snapshot.fetchedAt
            checkThresholds(snapshot.limits)   // marks already-passed thresholds as fired
        }

        DogHeaderView.animationEnabled = dogRunning
        if desktopWidget.shouldRestore { desktopWidget.show() }
        widgetItem.state = desktopWidget.isVisible ? .on : .off

        render()
        startMenuBarWatch()
        reload(trigger: .launch)

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.reload(trigger: .timer)
        }
        // The menu bar runs a modal run loop while its menu is open; without
        // .common the timer would stall for as long as the user holds it open.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Timers do not fire while the machine is asleep, and the first post-wake
        // tick can be up to a full interval away -- refresh immediately instead.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reload(trigger: .wake) }
    }

    /// Refresh the moment the menu opens, so the numbers a user actually reads are
    /// fetched on demand rather than up to one poll interval old -- unless we just
    /// fetched, in which case opening the menu again costs a request for nothing.
    /// After a hover prefetch this normally *is* the skipped case, which is the point:
    /// the request already went out while the pointer was travelling to the click.
    func menuDidClose(_ menu: NSMenu) {
        dogHeader.stopAnimating()
    }

    func menuWillOpen(_ menu: NSMenu) {
        dogHeader.startAnimating()
        hoverWork?.cancel()
        render()  // keeps the "N분 전 업데이트" line honest even when the fetch is skipped
        reloadOnDemand(.menuOpen)
    }

    /// Prefetch when the pointer enters the menu bar, not when it reaches this icon.
    ///
    /// The ring gauge is the thing people actually read -- you glance at it, you don't
    /// aim at it -- so waiting for a hover on a 20pt target would miss almost every
    /// look. It matters more under a fullscreen app, where the menu bar is hidden
    /// until the pointer is pushed to the top edge: that push *is* the moment the icon
    /// becomes visible, and starting the request there means the ring has caught up
    /// by the time the bar finishes animating in.
    ///
    /// A global monitor rather than a tracking area on the status item: mouse-move
    /// monitors need no accessibility permission, and this has to work while the menu
    /// bar (and therefore the button) is still hidden, which a tracking area on that
    /// button cannot do.
    private func startMenuBarWatch() {
        rebuildMenuBarBands()
        // Seed from where the pointer actually is. The crossing test is edge-triggered,
        // so assuming "outside" at launch would be wrong exactly when the user has just
        // reached up to the menu bar -- and it would then take a trip out and back to
        // arm at all.
        pointerInMenuBar = isInMenuBar(NSEvent.mouseLocation)

        // Screens come and go, and each arrival can move every menu bar's y position:
        // plugging in a taller external display shifts the global coordinate space, so
        // a threshold cached against the old layout would point at empty space.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildMenuBarBands() }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in self?.pointerMoved(to: NSEvent.mouseLocation)
        }
    }

    /// Precomputed "menu bar starts at this y" per screen.
    ///
    /// A moving pointer delivers on the order of a hundred events a second, and the
    /// honest test -- find the screen containing the point, ask NSStatusBar for the
    /// menu bar thickness, read `visibleFrame` -- queries the window server on every
    /// one of them. None of those answers change unless the display layout does, so
    /// they are computed once here and the per-event path becomes arithmetic.
    private var menuBarBands: [(frame: NSRect, thresholdY: CGFloat)] = []

    private var lowestThresholdY: CGFloat = .greatestFiniteMagnitude

    /// Arming gate: how close to a top edge is worth looking at closely. Never decides
    /// the answer, only whether to start asking -- but it does have to be at least
    /// `responsiveBand`, or points that would qualify never get checked.
    private static let maxMenuBarHeight: CGFloat = 30

    /// How far down from the top edge still counts as asking for the menu bar.
    ///
    /// Narrow on purpose: the gesture this recognises is *pushing the pointer into the
    /// top edge*, not merely being somewhere in the menu bar's strip. Anything wider
    /// fires while crossing the bar on the way to somewhere else, which is the whole
    /// complaint -- and it fires hardest under a fullscreen app, where that strip is
    /// the app's own content rather than a menu bar at all.
    ///
    /// This only ever applies while the bar is actually on screen, which is what lets
    /// it be roomy. With the bar hidden the strictness comes from somewhere else
    /// entirely -- the bar has to come down first, and only pressing into the very top
    /// edge does that -- so being generous here cannot leak into the fullscreen case
    /// that the narrow zone existed to protect.
    ///
    /// Wide enough to include the icon itself, which sits below the top of the bar:
    /// a zone that excluded it would refuse the most deliberate gesture there is.
    private static let responsiveBand: CGFloat = 20


    private func rebuildMenuBarBands() {
        menuBarBands = NSScreen.screens.map { ($0.frame, $0.frame.maxY - Self.maxMenuBarHeight) }
        lowestThresholdY = menuBarBands.map(\.thresholdY).min() ?? .greatestFiniteMagnitude
    }

    /// Edge-triggered: only a crossing into the band schedules work, so resting in the
    /// menu bar doesn't re-arm on every one of the ~100 events a second a moving mouse
    /// produces. The band is the menu bar's own height, which is also correct while
    /// it's hidden -- `visibleFrame` then equals `frame`, and the thickness stands in.
    /// Is the pointer on the icon itself's strip of menu bar, right now?
    ///
    /// Not a coordinate heuristic. macOS parks the status item's window above every
    /// screen while the menu bar is hidden, and drops it into the bar of whichever
    /// screen currently owns the menu bar when it shows -- observed moving between
    /// `1043..1073` (off every screen), `949..982` (the notched display's bar) and
    /// `1013..1043` (the external display's bar). So the window's own frame answers
    /// two questions no amount of measuring the top edge can:
    ///
    /// - **Is the bar actually showing?** Under a fullscreen app the top strip belongs
    ///   to that app, not to a menu bar. Guessing by proximity fires when the user
    ///   reaches for a tab, which is the complaint this replaces.
    /// - **Which screen is it showing on?** The icon exists on exactly one. Hovering
    ///   the other display's menu bar cannot be someone looking at a ring that isn't
    ///   drawn there.
    ///
    /// The answer is only correct at the instant it is asked, which is why the dwell
    /// re-asks: pushing into the top edge of a fullscreen app arms the timer, the bar
    /// slides down during those 300ms, and the check then passes. A pointer that
    /// merely passed near the top never reveals anything, so it never fires.
    private func isInMenuBar(_ point: NSPoint) -> Bool {
        guard let barFrame = statusItem.button?.window?.frame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(barFrame) })
        else { return false }
        // The bar's own bottom edge, pulled up to the responsive band when the bar is
        // taller than that -- whichever is lower down the screen wins, so the zone can
        // never extend past the bar itself.
        let threshold = max(barFrame.minY, screen.frame.maxY - Self.responsiveBand)
        return screen.frame.contains(point) && point.y >= threshold
    }

    /// Cheap gate for arming the dwell: near the top of some screen. Deliberately
    /// generous and deliberately not the decision -- `isInMenuBar` decides, 300ms
    /// later, once the bar has had time to appear.
    private func isNearTopEdge(_ point: NSPoint) -> Bool {
        point.y >= lowestThresholdY
            && menuBarBands.contains { $0.frame.contains(point) && point.y >= $0.thresholdY }
    }

    private func pointerMoved(to point: NSPoint) {
        let near = isNearTopEdge(point)
        guard near != pointerInMenuBar else { return }
        pointerInMenuBar = near
        hoverWork?.cancel()
        guard near else { hoverWork = nil; return }

        // Arm only. Whether this counts as being in the menu bar is decided later, by
        // which point a hidden bar has had time to slide down -- or to stay hidden,
        // which is the answer for a pointer only passing near the top of a fullscreen
        // window.
        armMenuBarCheck(attemptsLeft: Self.hoverCheckAttempts)
    }

    /// Re-asks rather than deciding once.
    ///
    /// Under a fullscreen app the bar is not down at the instant the pointer reaches
    /// the edge -- it slides in, and how long that takes is not ours to know. A single
    /// check at 300ms would answer "no menu bar" for a gesture that is in the middle of
    /// summoning one, which would be indistinguishable from the feature being broken.
    /// Checking again a few times costs nothing (it is a frame comparison, and it stops
    /// the moment the pointer leaves) and removes the guess about reveal timing.
    private func armMenuBarCheck(attemptsLeft: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isInMenuBar(NSEvent.mouseLocation) {
                self.reloadOnDemand(.menuBar)
            } else if attemptsLeft > 1 {
                self.armMenuBarCheck(attemptsLeft: attemptsLeft - 1)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: work)
    }

    /// Someone is looking right now, so go and ask -- past the cache, past any backoff.
    /// The background poll can afford to be patient; this cannot, because being wrong
    /// at the exact moment a person reads the rings is the only failure that shows.
    ///
    /// Bypassing the cooldown is safe: a 429 is refused in about 30ms and observably
    /// does not extend the block (its Retry-After counts down whether or not you keep
    /// asking), so the cost of trying is a round trip, and the cost of not trying is a
    /// stale number in front of someone who came to read it.
    private func reloadOnDemand(_ trigger: RefreshTrigger) {
        let floor = trigger == .menuBar ? Self.hoverMinInterval : Self.onDemandMinInterval
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < floor { return }
        reload(force: true, trigger: trigger)
    }

    /// On by default -- it is the character the app is built around. Off is for
    /// anyone who would rather have the ~2% of a core back, measured while the widget
    /// is open; the menu's dog only ever runs while the menu is up.
    private var dogRunning: Bool {
        get { UserDefaults.standard.object(forKey: Self.runningDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.runningDefaultsKey) }
    }

    @objc private func toggleRunning() {
        dogRunning.toggle()
        runningItem.state = dogRunning ? .on : .off
        DogHeaderView.animationEnabled = dogRunning
    }

    @objc private func toggleWidget() {
        desktopWidget.toggle()
        widgetItem.state = desktopWidget.isVisible ? .on : .off
    }

    @objc private func refresh() {
        reload(force: true, trigger: .manual)
    }

    /// Small caps-style section label; unclickable (nil action) like the info rows above.
    private static func headerMenuItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func setStatusLine(_ text: String) {
        statusMenuItem.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        let mode: DisplayMode = sender.tag == 0 ? .icon : .text
        guard mode != displayMode else { return }
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.displayModeDefaultsKey)
        updateModeMenuState()
        render()
    }

    private func updateModeMenuState() {
        iconModeMenuItem.state = displayMode == .icon ? .on : .off
        textModeMenuItem.state = displayMode == .text ? .on : .off
    }

    /// `force` means a person asked: skip the backoff and the cache, and go to the
    /// network. Unforced means the timer asked, and the timer can wait.
    private func reload(force: Bool = false, trigger: RefreshTrigger) {
        // Not a delay but a correctness guard: two overlapping requests would spend
        // two slots of a tight budget to answer one question.
        guard !inFlight else { return }
        if !force, let blockedUntil, blockedUntil > Date() {
            // Re-render anyway so the countdown in the status line keeps moving.
            render()
            return
        }

        inFlight = true
        lastAttempt = Date()

        // `inFlight` exists to stop overlapping requests, but it also means a fetch
        // that never calls back freezes the app permanently: every later refresh --
        // timer, hover, menu, explicit -- returns at that first guard, silently, while
        // the rings sit on numbers that quietly go hours out of date. Nothing in the
        // UI would say so. Time it out instead of trusting the callback to arrive.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.inFlight else { return }
            self.inFlight = false
            self.lastFailure = .transport(URLError(.timedOut))
            self.consecutiveFailures += 1
            self.blockedUntil = Date().addingTimeInterval(
                Self.cooldown(for: .transport(URLError(.timedOut)), attempt: self.consecutiveFailures))
            self.render()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fetchWatchdog, execute: watchdog)

        UsageAPI.fetch(allowCache: !force) { [weak self] result in
            guard let self else { return }
            watchdog.cancel()
            self.inFlight = false
            switch result {
            case .success(let snapshot):
                self.lastFailure = nil
                self.lastSuccess = snapshot.fetchedAt
                self.blockedUntil = nil
                self.consecutiveFailures = 0
                self.checkThresholds(snapshot.limits)
                self.limits = snapshot.limits
            case .failure(let error):
                // Keep the previous numbers; render() labels them as stale. Blanking
                // on a single failed poll would make a 5-second wifi hiccup look like
                // a logged-out account.
                self.lastFailure = error
                self.consecutiveFailures += 1
                self.blockedUntil = Date().addingTimeInterval(Self.cooldown(for: error,
                                                                            attempt: self.consecutiveFailures))
            }
            self.render()
        }
    }

    /// How long to stay quiet after a failure. A 429 dictates its own wait; everything
    /// else backs off geometrically up to the poll interval, so a dead network or a
    /// logged-out account settles into the normal cadence instead of retrying hard.
    private static func cooldown(for failure: UsageAPI.Failure, attempt: Int) -> TimeInterval {
        let backoff = 30 * pow(2, Double(min(attempt, 6) - 1))   // 30 60 120 240 480 960
        // A 429 can carry `Retry-After: 0` and still keep answering 429 -- the short
        // window has reset but a longer one hasn't, and the server doesn't say how
        // long that is. Obeying the 0 literally means retrying every 30s into a wall,
        // so the server's number is a floor, never a ceiling.
        if case .rateLimited(let retryAfter) = failure { return max(retryAfter, min(900, backoff)) }
        return min(pollInterval, backoff)
    }

    /// Test seam: `cooldown` is private, and this is the only rule in the file with
    /// enough arithmetic to get quietly wrong.
    static func cooldownForTest(_ failure: UsageAPI.Failure, attempt: Int) -> TimeInterval {
        cooldown(for: failure, attempt: attempt)
    }

    /// Fires a local notification the first time a row reaches each of notifyThresholds
    /// within its current window. On the very first load, thresholds already passed are
    /// marked fired without notifying -- otherwise launching the app mid-window at, say,
    /// 80% would immediately fire all three at once.
    private func checkThresholds(_ limits: [UsageLimit]) {
        defer {
            for limit in limits { knownResets[limit.id] = limit.resetsAt }
        }

        guard hasSeenFirstLoad else {
            hasSeenFirstLoad = true
            for limit in limits {
                firedThresholds[limit.id] = Set(Self.notifyThresholds.filter { limit.percent >= $0 })
            }
            return
        }

        for limit in limits {
            // A new window means thresholds may fire again.
            if let previous = knownResets[limit.id], !Self.isSameWindow(previous, limit.resetsAt) {
                firedThresholds[limit.id] = []
            }
            var fired = firedThresholds[limit.id] ?? []
            for threshold in Self.notifyThresholds where limit.percent >= threshold && !fired.contains(threshold) {
                fired.insert(threshold)
                let mood = DogMood(percent: limit.percent)
                notify(title: "\(limit.title)를 \(Int(threshold))% 썼어요",
                       body: "\(mood.line) · \(Self.relativeReset(limit.resetsAt))",
                       mood: mood)
            }
            firedThresholds[limit.id] = fired
        }
    }

    /// Whether two `resets_at` readings describe the same window.
    ///
    /// Not equality, because the server computes the field as "now + time remaining"
    /// and so returns a slightly different instant on every call -- observed drifting
    /// across a second boundary (`22:00:00` one fetch, `21:59:59` the next). Compared
    /// exactly, that reads as a window rollover, which clears the fired-threshold set
    /// and re-fires every notification the limit has already passed. That is the bug
    /// where a limit sitting still at 50% announces itself over and over.
    ///
    /// A real rollover moves this by the length of the window -- five hours at the
    /// shortest -- so any tolerance between the jitter and that is safe.
    private static let sameWindowTolerance: TimeInterval = 300

    private static func isSameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (first?, second?): return abs(first.timeIntervalSince(second)) < sameWindowTolerance
        default: return false
        }
    }

    static func isSameWindowForTest(_ a: Date?, _ b: Date?) -> Bool { isSameWindow(a, b) }

    /// The same dog delivers the news.
    ///
    /// A bare "주간 · Fable 50%" leaves the reader to decide whether that is good or
    /// bad, in a glance at a banner that is already sliding away. Attaching the mood
    /// art means the tone lands before the text is even read, and it is the same
    /// character they just saw in the menu rather than a second visual language.
    private func notify(title: String, body: String, mood: DogMood) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let attachment = Self.moodAttachment(mood) { content.attachments = [attachment] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Renders the mood art to a file UNNotification can attach.
    ///
    /// Written once per mood and reused: the notification centre copies the file into
    /// its own store when the request is posted, so re-rendering on every threshold
    /// crossing would be pure waste. Kept beside the usage cache so uninstalling takes
    /// the whole directory with it.
    private static func moodAttachment(_ mood: DogMood) -> UNNotificationAttachment? {
        let directory = UsageCache.url.deletingLastPathComponent().appendingPathComponent("mood")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(mood).png")

        if !FileManager.default.fileExists(atPath: url.path) {
            let size = NSSize(width: 256, height: 208)
            let image = NSImage(size: size, flipped: false) { rect in
                // Supplied art brings its own margins; the drawn version needs some
                // added or it touches the edges of the notification thumbnail.
                if let frame = DogArt.frames(mood: mood, size: size).first, DogArt.usesSuppliedArt {
                    frame.draw(in: DogHeaderView.fit(frame.size, into: rect.insetBy(dx: 10, dy: 10)))
                } else {
                    DogArt.draw(mood: mood, in: rect.insetBy(dx: 18, dy: 18))
                }
                return true
            }
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: url)) != nil
            else { return nil }
        }
        return try? UNNotificationAttachment(identifier: "dog-\(mood)", url: url)
    }

    /// Sets the button's image via a nil-then-set toggle instead of a direct
    /// assignment. Assigning a new NSImage directly (even a distinct instance)
    /// has been observed to leave AppKit showing the previous bitmap -- clearing
    /// it first forces a real add/remove transition instead of an in-place swap
    /// AppKit might coalesce away.
    private func setIcon(_ image: NSImage?) {
        statusItem.button?.image = nil
        statusItem.button?.image = image
    }

    private func render() {
        for (index, item) in rowItems.enumerated() {
            guard index < limits.count else { item.isHidden = true; continue }
            let limit = limits[index]
            item.isHidden = false
            rowViews[index].update(title: limit.title,
                                   percent: limit.percent,
                                   subtitle: Self.relativeReset(limit.resetsAt))
        }

        // The dog speaks for whichever limit is closest to stopping you -- the highest
        // percentage, not the first row. Averaging or picking by order would make it
        // cheerful right up until something you were not watching cut you off.
        let binding = limits.max { $0.percent < $1.percent }
        dogHeader.update(limit: binding, reset: Self.relativeReset(binding?.resetsAt))

        desktopWidget.update(limits: limits, status: statusText()) { Self.relativeReset($0) }

        setStatusLine(statusText())
        // The freshness line goes in the tooltip too, not just the dropdown: a number
        // with no age on it is the thing that makes a stale reading look like a wrong
        // one. This way the answer to "is this current?" costs a hover, not a click.
        statusItem.button?.toolTip = limits.isEmpty
            ? statusText()
            : (limits.map { String(format: "%@: %.0f%% · %@", $0.title, $0.percent, Self.relativeReset($0.resetsAt)) }
                     + [statusText()]).joined(separator: "\n")

        // Outer ring tracks the session cap; inner tracks the *tightest* weekly cap,
        // since that -- not the all-models average -- is what actually cuts you off.
        let session = limits.first { $0.group == "session" }?.percent
        let week = limits.filter { $0.group == "weekly" }.map(\.percent).max()

        guard let session, let week else {
            setIcon(IconFactory.unknownIcon())
            statusItem.button?.title = ""
            statusItem.button?.needsDisplay = true
            return
        }
        let stale = isStale
        switch displayMode {
        case .icon:
            setIcon(IconFactory.dualRingIcon(session: session, week: week, stale: stale))
            // Cleared as an attributed string: text mode sets attributedTitle, and a
            // plain `title = ""` does not reliably clear the attributed one.
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
        case .text:
            setIcon(nil)
            let text = String(format: "%.0f%%/%.0f%%", session, week)
            statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ])
        }
        // Assigning a new image/title doesn't always trigger a repaint on its own --
        // e.g. after the display wakes from sleep, or the display configuration
        // changes (external monitor connect/disconnect), AppKit has been seen to
        // keep showing the previous bitmap indefinitely, surviving even an explicit
        // needsDisplay and a manual refresh. Force it explicitly so the icon can't
        // visibly go stale while the underlying data (checkable via the tooltip/
        // dropdown) is fine. Belt and suspenders: the view-level flag plus a
        // direct layer invalidation, since the button is layer-backed and a
        // stuck backing-store layer is exactly what display/config changes cause.
        statusItem.button?.needsDisplay = true
        statusItem.button?.layer?.setNeedsDisplay()
        scheduleStalenessRedraw()
    }

    /// Past this age the numbers stop being presented as current. Not tied to the poll
    /// interval: what counts as "too old to trust at a glance" is a property of the
    /// data, not of how lazily we happen to be polling it.
    private static let staleAfter: TimeInterval = 900

    private var isStale: Bool {
        guard let lastSuccess else { return true }
        return Date().timeIntervalSince(lastSuccess) > Self.staleAfter
    }

    /// Nothing redraws the rings on its own, so without this the colour drains only
    /// when some *other* event happens to call render() -- which, with a ten-minute
    /// poll and a backoff that can run longer, means numbers can sit there looking
    /// authoritative well past the point they stopped being trustworthy. Draw the
    /// moment it actually goes stale, not the next time we happen to look.
    private func scheduleStalenessRedraw() {
        stalenessTimer?.invalidate()
        stalenessTimer = nil
        guard let lastSuccess else { return }
        let remaining = Self.staleAfter - Date().timeIntervalSince(lastSuccess)
        guard remaining > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            self?.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        stalenessTimer = timer
    }

    /// The line under the rows: how fresh the numbers are, or why they aren't.
    private func statusText() -> String {
        if let failure = lastFailure {
            var reason: String
            switch failure {
            case .noToken:      reason = "Claude Code 로그인 필요"
            case .unauthorized: reason = "토큰 만료 · Claude Code 실행 시 갱신됨"
            case .rateLimited:  reason = "요청 제한"
            case .http(let c):  reason = "서버 오류 (\(c))"
            case .transport:    reason = "연결 실패"
            case .malformed:    reason = "응답 형식 오류"
            }
            // Say when it will try again, so a cooldown doesn't read as a dead app.
            if let blockedUntil, case let wait = Int(blockedUntil.timeIntervalSinceNow), wait > 0 {
                reason += wait < 60 ? " · \(wait)초 후 재시도" : " · \(wait / 60)분 후 재시도"
            }
            guard lastSuccess != nil else { return reason }
            return "\(reason) · 마지막 값 표시 중"
        }
        guard let lastSuccess else { return "불러오는 중..." }
        let seconds = Int(Date().timeIntervalSince(lastSuccess))
        if seconds < 10 { return "방금 업데이트됨" }
        if seconds < 60 { return "\(seconds)초 전 업데이트" }
        return "\(seconds / 60)분 전 업데이트"
    }

    /// Matches the phrasing in Claude's own usage popup: a relative countdown at
    /// whatever granularity keeps the number small ("1시간 후 초기화", "2일 후 초기화").
    static func relativeReset(_ date: Date?) -> String {
        guard let date else { return "-" }
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "곧 초기화" }
        if minutes < 60 { return "\(minutes)분 후 초기화" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 후 초기화" }
        return "\(hours / 24)일 후 초기화"
    }
}

// MARK: - Self-check

/// `Clife --selftest` -- exercises the parsing that has no other runnable check
/// (date stripping, limits mapping, row titles) against a captured API payload.
private func selfTest() -> Never {
    let payload = """
    {"limits":[
      {"kind":"session","group":"session","percent":17,"resets_at":"2026-09-20T09:10:00.606234+00:00","scope":null},
      {"kind":"weekly_all","group":"weekly","percent":36,"resets_at":"2026-09-22T22:00:00.606253+00:00","scope":null},
      {"kind":"weekly_scoped","group":"weekly","percent":39,"resets_at":"2026-09-22T21:59:59.606486+00:00",
       "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
      {"kind":"broken"}
    ]}
    """.data(using: .utf8)!

    let limits = try! UsageAPI.decode(payload)
    precondition(limits.count == 3, "rows missing a required field must be dropped, got \(limits.count)")
    precondition(limits.map(\.percent) == [17, 36, 39])
    precondition(limits[0].title == "5시간 한도")
    precondition(limits[1].title == "주간 · 모든 모델")
    precondition(limits[2].title == "주간 · Fable")
    precondition(limits[2].id == "weekly_scoped:Fable")

    // Two scoped rows with no model name must not collapse onto one identity, or they
    // share a set of fired thresholds and one of them silently stops notifying.
    let scoped = try! UsageAPI.decode("""
    {"limits":[
      {"kind":"weekly_scoped","group":"weekly","percent":10,"scope":{"surface":"code"}},
      {"kind":"weekly_scoped","group":"weekly","percent":20,"scope":{"surface":"chat"}}
    ]}
    """.data(using: .utf8)!)
    precondition(Set(scoped.map(\.id)).count == 2, "\(scoped.map(\.id))")

    // The server recomputes resets_at as "now + remaining" on every call, so the same
    // window comes back a second apart -- observed straddling a second boundary. Read
    // as a rollover, that re-fires every notification the limit already passed.
    let a = UsageAPI.parseDate("2026-09-22T22:00:00.390309+00:00")
    let b = UsageAPI.parseDate("2026-09-22T21:59:59.801084+00:00")
    precondition(a != b, "the two readings really are different instants")
    precondition(AppDelegate.isSameWindowForTest(a, b), "1s of jitter must not read as a new window")
    // A genuine rollover moves by the window length; five hours is the shortest one.
    let next = a!.addingTimeInterval(5 * 3600)
    precondition(!AppDelegate.isSameWindowForTest(a, next), "a real rollover must still be detected")
    precondition(AppDelegate.isSameWindowForTest(nil, nil))
    precondition(!AppDelegate.isSameWindowForTest(a, nil))

    // Six fractional digits plus a "+00:00" offset must survive parsing.
    let reset = limits[0].resetsAt!
    precondition(Int(reset.timeIntervalSince1970) == 1789895400, "got \(reset.timeIntervalSince1970)")
    precondition(UsageAPI.parseDate("2026-09-20T09:10:00Z") != nil, "fractionless timestamps must parse too")
    precondition(UsageAPI.parseDate("not a date") == nil)

    let hour = Date().addingTimeInterval(3600 + 30)
    precondition(AppDelegate.relativeReset(hour) == "1시간 후 초기화", AppDelegate.relativeReset(hour))
    precondition(AppDelegate.relativeReset(Date().addingTimeInterval(2 * 86400 + 60)) == "2일 후 초기화")
    precondition(AppDelegate.relativeReset(Date().addingTimeInterval(-60)) == "곧 초기화")
    precondition(AppDelegate.relativeReset(nil) == "-")

    // A 429's Retry-After is a floor: never retry sooner than the server said.
    precondition(AppDelegate.cooldownForTest(.rateLimited(retryAfter: 296), attempt: 1) == 296)
    // ...but never trust it as a ceiling either. The endpoint really does answer
    // `Retry-After: 0` while still refusing every request, so repeated 429s have to
    // back off on their own instead of hammering every 30s.
    let limited = (1...7).map { AppDelegate.cooldownForTest(.rateLimited(retryAfter: 0), attempt: $0) }
    precondition(limited == [30, 60, 120, 240, 480, 900, 900], "\(limited)")
    // Everything else backs off geometrically and saturates at the poll interval.
    let backoff = (1...6).map { AppDelegate.cooldownForTest(.transport(UsageAPI.Failure.malformed), attempt: $0) }
    precondition(backoff == [30, 60, 120, 240, 480, 600], "\(backoff)")

    print("selftest OK")
    exit(0)
}

/// `Clife --probe` -- runs one real fetch through the exact code path the app uses
/// (same URLSession defaults, same headers, same User-Agent, same keychain read) and
/// reports what came back. `curl` cannot stand in for this: it is a different client,
/// and "works in curl, fails in the app" is precisely the gap that needs closing.
private func probe() -> Never {
    let cache = UsageCache.read()
    print("cache: " + (cache.map { "\(Int(-$0.fetchedAt.timeIntervalSinceNow))s old, \($0.data.count) B" }
                       ?? "none"))

    var outcome: String?
    UsageAPI.fetch { result in
        switch result {
        case .success(let snapshot):
            let age = Int(-snapshot.fetchedAt.timeIntervalSinceNow)
            outcome = "OK  " + snapshot.limits
                .map { String(format: "%@=%.0f%%", $0.kind, $0.percent) }
                .joined(separator: " ") + "  (age \(age)s)"
        case .failure(let error):
            outcome = "FAIL \(error)"
        }
    }

    // The run loop has to keep turning: fetch delivers its result on the main queue,
    // which in the app is serviced by AppKit. Blocking the main thread here (on a
    // semaphore, say) would deadlock the probe and frame it as an app hang.
    // Generously past the 15s request timeout, so a real hang is distinguishable
    // from a slow network rather than both looking like "it didn't work".
    let deadline = Date().addingTimeInterval(25)
    while outcome == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    guard let outcome else {
        print("result: timed out after 25s")
        exit(2)
    }
    print("result: \(outcome)")
    exit(0)
}

/// `Clife --dogsheet <path.png>` -- renders every mood to one image.
///
/// The art is hand-ported from SVG into Core Graphics coordinates, which is exactly
/// the kind of work that compiles cleanly while drawing something wrong. This is how
/// the port gets looked at instead of assumed.
private func dogSheet() -> Never {
    let path = CommandLine.arguments.last.map { ($0 as NSString).expandingTildeInPath }
        ?? "dogsheet.png"
    let moods: [DogMood] = [.energetic, .steady, .tired, .spent]
    // Six frames across one stride, so the gait can be judged as a sequence rather
    // than as four unrelated drawings. An animation that only looks right in motion
    // is an animation nobody can review.
    let phases: [CGFloat] = [0, 1.0/6, 2.0/6, 3.0/6, 4.0/6, 5.0/6]
    let cell = NSSize(width: 150, height: 122)
    let size = NSSize(width: cell.width * CGFloat(moods.count),
                      height: cell.height * CGFloat(phases.count))

    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (row, phase) in phases.enumerated() {
        let yOffset = size.height - cell.height * CGFloat(row + 1)
        for (index, mood) in moods.enumerated() {
            let x = cell.width * CGFloat(index)
            // A track under each, so the stance can be judged against the ground
            // it is supposed to be running on rather than floating in space.
            let track = NSBezierPath()
            track.move(to: CGPoint(x: x + 14, y: yOffset + 26))
            track.line(to: CGPoint(x: x + cell.width - 14, y: yOffset + 26))
            track.lineWidth = 6
            track.lineCapStyle = .round
            NSColor(white: 0.9, alpha: 1).setStroke()
            track.stroke()

            DogArt.draw(mood: mood,
                        in: NSRect(x: x + 24, y: yOffset + 24, width: 102, height: 84),
                        phase: phase)
        }
        }
        return true
    }

    guard let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: path))) != nil
    else { print("failed to write \(path)"); exit(1) }
    print("wrote \(path)")

    // The menu itself, too. Its layout is Auto Layout inside NSMenuItem views, which
    // is not something you can eyeball in a running menu -- it closes the moment you
    // try to capture it. Rendering the same views offscreen is the only way to see
    // what was actually built.
    let menuPath = (path as NSString).deletingPathExtension + "-menu.png"
    let width: CGFloat = 288
    let header = DogHeaderView()
    header.frame = NSRect(x: 0, y: 0, width: width, height: 68)
    header.update(limit: sampleLimits[0], reset: "4시간 12분 후 초기화")

    let rows = sampleLimits.map { limit -> UsageRowView in
        let row = UsageRowView()
        row.frame = NSRect(x: 0, y: 0, width: width, height: 54)
        row.update(title: limit.title, percent: limit.percent, subtitle: "2일 후 초기화")
        return row
    }

    let stack = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                     height: 68 + CGFloat(rows.count) * 54))
    var y = stack.bounds.height
    for view in [header] as [NSView] + rows {
        y -= view.frame.height
        view.setFrameOrigin(NSPoint(x: 0, y: y))
        stack.addSubview(view)
    }
    stack.layoutSubtreeIfNeeded()

    // Detached views have no window, so they inherit no appearance and would render
    // label text in whatever the default is -- against a transparent background that
    // reads as black, which is how "the labels are missing" gets misdiagnosed.
    stack.appearance = NSAppearance(named: .aqua)
    guard let rep = stack.bitmapImageRepForCachingDisplay(in: stack.bounds) else { exit(1) }
    stack.cacheDisplay(in: stack.bounds, to: rep)

    // cacheDisplay clears the rep, so the backdrop has to be composited afterwards.
    let sheet = NSImage(size: stack.bounds.size, flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        rep.draw(in: rect)
        return true
    }
    if let tiff = sheet.tiffRepresentation,
       let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: menuPath))
        print("wrote \(menuPath)")
    }
    exit(0)
}

/// Stand-in numbers for the offscreen previews, shaped like a real response.
private let sampleLimits: [UsageLimit] = [
    UsageLimit(kind: "session", group: "session", percent: 82,
               resetsAt: Date().addingTimeInterval(3600), scopeModel: nil, scopeSurface: nil),
    UsageLimit(kind: "weekly_all", group: "weekly", percent: 62,
               resetsAt: Date().addingTimeInterval(172800), scopeModel: nil, scopeSurface: nil),
    UsageLimit(kind: "weekly_scoped", group: "weekly", percent: 50,
               resetsAt: Date().addingTimeInterval(172800), scopeModel: "Fable", scopeSurface: nil),
]

if CommandLine.arguments.contains("--selftest") { selfTest() }
if CommandLine.arguments.contains("--dogsheet") { dogSheet() }
if CommandLine.arguments.contains("--probe") { probe() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
