import Cocoa

// MARK: - Dog

/// How hard the dog is having to run. Derived from a percentage, so the same
/// number drives the drawing, the wording and the colour without three separate
/// thresholds drifting apart.
enum DogMood {
    case energetic   // 0-50
    case steady      // 50-70
    case tired       // 70-90
    case spent       // 90+

    init(percent: Double) {
        switch percent {
        case ..<50:  self = .energetic
        case ..<70:  self = .steady
        case ..<90:  self = .tired
        default:     self = .spent
        }
    }

    /// What the dog says about the limit it is running on. First person, because
    /// the point of the character is that a number arrives as news from someone
    /// rather than as a measurement you have to interpret.
    var line: String {
        switch self {
        case .energetic: return "아직 쌩쌩해요!"
        case .steady:    return "반 넘게 달렸어요"
        case .tired:     return "조금 지쳐가요…"
        case .spent:     return "잠깐 쉬어야 할 것 같아요"
        }
    }

    var tint: NSColor {
        switch self {
        case .energetic, .steady: return DogArt.ok
        case .tired:              return DogArt.warn
        case .spent:              return DogArt.hot
        }
    }
}

/// The dog, drawn in code.
///
/// Ported from `design/dog/states.html`, which exists so the poses can be judged
/// at real size before any of this is written. The SVG there is deliberately
/// restricted to ellipses, round-capped strokes and quadratic curves -- every one
/// of which has a direct NSBezierPath equivalent -- so the two stay in step
/// instead of the drawing quietly diverging from the thing that was approved.
///
/// Coordinates are the SVG's: a 64x52 box with y increasing downward. `draw`
/// flips once at the top rather than every path being mentally inverted.
enum DogArt {
    static let ink      = NSColor(srgbRed: 0.227, green: 0.180, blue: 0.153, alpha: 1)   // #3A2E27
    static let fur      = NSColor(srgbRed: 0.941, green: 0.824, blue: 0.675, alpha: 1)   // #F0D2AC
    static let furDark  = NSColor(srgbRed: 0.847, green: 0.659, blue: 0.455, alpha: 1)   // #D8A874
    static let collar   = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // #D97757
    static let tag      = NSColor(srgbRed: 0.910, green: 0.722, blue: 0.294, alpha: 1)   // #E8B84B
    static let sweat    = NSColor(srgbRed: 0.498, green: 0.722, blue: 0.878, alpha: 1)   // #7FB8E0
    static let ok       = NSColor(srgbRed: 0.298, green: 0.686, blue: 0.490, alpha: 1)   // #4CAF7D
    static let warn     = NSColor(srgbRed: 0.878, green: 0.639, blue: 0.243, alpha: 1)   // #E0A33E
    static let hot      = NSColor(srgbRed: 0.851, green: 0.325, blue: 0.310, alpha: 1)   // #D9534F

    /// Design-space canvas. Larger than the dog because the poses reach outside the
    /// body box -- a flying ear goes to y = -4, the tail to x = -4, a stretched hind
    /// leg to y = 47. Sized to the extremes with a margin so nothing is clipped at
    /// the one moment it matters, which is the pose where the ear is flying.
    static let box = NSSize(width: 112, height: 82)
    private static let contentOffset = CGPoint(x: 2, y: 2)

    // MARK: Pose data

    private struct Pose {
        var legs: [(CGPoint, CGPoint)]
        /// The other half of the stride. Drawing runs by blending between two keyed
        /// frames rather than by keeping a sprite sheet: two poses and an ease read as
        /// a gallop, and there is nothing to keep in sync when a pose is retouched.
        var legsAlt: [(CGPoint, CGPoint)]
        /// Dust only where the dog is pushing off hard. A sitting dog kicking up dirt
        /// would undercut the one thing that pose has to say.
        var kicksDust: Bool
        var tail: (from: CGPoint, control: CGPoint, to: CGPoint)
        var bodyCenter: CGPoint
        var bodyRadii: CGSize
        var headCenter: CGPoint
        /// Ear as two quadratic curves closed back to the root -- a leaf shape.
        var ear: (root: CGPoint, c1: CGPoint, mid: CGPoint, c2: CGPoint, back: CGPoint)
        var muzzleCenter: CGPoint
        var noseCenter: CGPoint
        /// Happy/shut eye is an arc; an open eye is a dot. Only one is ever set.
        var eyeArc: (from: CGPoint, control: CGPoint, to: CGPoint)?
        var eyeDot: CGPoint?
        var tongue: (from: CGPoint, control: CGPoint, to: CGPoint)?
        var collar: (from: CGPoint, control: CGPoint, to: CGPoint)
        var tagCenter: CGPoint
        var sweat: [(CGPoint, CGFloat)]
    }

    private static func pose(for mood: DogMood) -> Pose {
        // Coordinates are lifted straight from design/dog/states.html -- the B silhouette,
        // picked because it was the only candidate still legible as a dog at 46pt. The two
        // features doing that work are the ear hanging behind the head and the muzzle
        // sitting outside the head circle; an earlier pass buried the muzzle inside the
        // head and the whole thing read as a sheep.
        switch mood {
        case .energetic:
            return Pose(
                legs: [(CGPoint(x: 26, y: 54), CGPoint(x: 14, y: 72)),
                       (CGPoint(x: 38, y: 56), CGPoint(x: 28, y: 76)),
                       (CGPoint(x: 52, y: 56), CGPoint(x: 64, y: 76)),
                       (CGPoint(x: 62, y: 54), CGPoint(x: 78, y: 70))],
                legsAlt: [(CGPoint(x: 26, y: 54), CGPoint(x: 22, y: 68)),
                          (CGPoint(x: 38, y: 56), CGPoint(x: 36, y: 70)),
                          (CGPoint(x: 52, y: 56), CGPoint(x: 54, y: 70)),
                          (CGPoint(x: 62, y: 54), CGPoint(x: 66, y: 68))],
                kicksDust: true,
                tail: (CGPoint(x: 18, y: 38), CGPoint(x: 4, y: 30), CGPoint(x: 6, y: 14)),
                bodyCenter: CGPoint(x: 42, y: 40), bodyRadii: CGSize(width: 24, height: 15),
                headCenter: CGPoint(x: 74, y: 28),
                ear: (CGPoint(x: 68, y: 13), CGPoint(x: 52, y: 8), CGPoint(x: 50, y: 26),
                      CGPoint(x: 58, y: 38), CGPoint(x: 70, y: 30)),
                muzzleCenter: CGPoint(x: 94, y: 34), noseCenter: CGPoint(x: 101, y: 31),
                eyeArc: (CGPoint(x: 79, y: 23), CGPoint(x: 83, y: 19), CGPoint(x: 87, y: 23)),
                eyeDot: nil, tongue: nil,
                collar: (CGPoint(x: 34, y: 28), CGPoint(x: 37, y: 40), CGPoint(x: 35, y: 50)),
                tagCenter: CGPoint(x: 35.5, y: 52), sweat: [])

        case .steady:
            return Pose(
                legs: [(CGPoint(x: 27, y: 54), CGPoint(x: 20, y: 72)),
                       (CGPoint(x: 39, y: 56), CGPoint(x: 35, y: 74)),
                       (CGPoint(x: 51, y: 56), CGPoint(x: 55, y: 74)),
                       (CGPoint(x: 62, y: 54), CGPoint(x: 70, y: 71))],
                legsAlt: [(CGPoint(x: 27, y: 54), CGPoint(x: 25, y: 68)),
                          (CGPoint(x: 39, y: 56), CGPoint(x: 40, y: 69)),
                          (CGPoint(x: 51, y: 56), CGPoint(x: 50, y: 69)),
                          (CGPoint(x: 62, y: 54), CGPoint(x: 64, y: 68))],
                kicksDust: true,
                tail: (CGPoint(x: 18, y: 38), CGPoint(x: 5, y: 33), CGPoint(x: 6, y: 20)),
                bodyCenter: CGPoint(x: 42, y: 40), bodyRadii: CGSize(width: 24, height: 15),
                headCenter: CGPoint(x: 74, y: 28),
                ear: (CGPoint(x: 68, y: 14), CGPoint(x: 52, y: 17), CGPoint(x: 53, y: 36),
                      CGPoint(x: 61, y: 45), CGPoint(x: 70, y: 31)),
                muzzleCenter: CGPoint(x: 94, y: 34), noseCenter: CGPoint(x: 101, y: 31),
                eyeArc: nil, eyeDot: CGPoint(x: 82, y: 24), tongue: nil,
                collar: (CGPoint(x: 34, y: 28), CGPoint(x: 37, y: 40), CGPoint(x: 35, y: 50)),
                tagCenter: CGPoint(x: 35.5, y: 52), sweat: [])

        case .tired:
            return Pose(
                legs: [(CGPoint(x: 28, y: 56), CGPoint(x: 26, y: 72)),
                       (CGPoint(x: 40, y: 58), CGPoint(x: 40, y: 74)),
                       (CGPoint(x: 50, y: 58), CGPoint(x: 51, y: 74)),
                       (CGPoint(x: 61, y: 56), CGPoint(x: 64, y: 72))],
                legsAlt: [(CGPoint(x: 28, y: 56), CGPoint(x: 30, y: 71)),
                          (CGPoint(x: 40, y: 58), CGPoint(x: 37, y: 73)),
                          (CGPoint(x: 50, y: 58), CGPoint(x: 54, y: 73)),
                          (CGPoint(x: 61, y: 56), CGPoint(x: 60, y: 71))],
                kicksDust: false,
                tail: (CGPoint(x: 18, y: 42), CGPoint(x: 6, y: 44), CGPoint(x: 3, y: 54)),
                bodyCenter: CGPoint(x: 42, y: 43), bodyRadii: CGSize(width: 24, height: 15),
                headCenter: CGPoint(x: 74, y: 32),
                ear: (CGPoint(x: 68, y: 19), CGPoint(x: 53, y: 24), CGPoint(x: 55, y: 44),
                      CGPoint(x: 63, y: 52), CGPoint(x: 71, y: 36)),
                muzzleCenter: CGPoint(x: 94, y: 38), noseCenter: CGPoint(x: 101, y: 35),
                eyeArc: (CGPoint(x: 79, y: 29), CGPoint(x: 83, y: 33), CGPoint(x: 87, y: 29)),
                eyeDot: nil,
                tongue: (CGPoint(x: 94, y: 45), CGPoint(x: 96, y: 53), CGPoint(x: 90, y: 54)),
                collar: (CGPoint(x: 34, y: 31), CGPoint(x: 37, y: 43), CGPoint(x: 35, y: 53)),
                tagCenter: CGPoint(x: 35.5, y: 55), sweat: [])

        case .spent:
            // Hind legs fold under the body, so only three show. A fourth would read as
            // standing, which is the one thing this pose must not say. No stride either --
            // the bob in draw() becomes breathing rather than running.
            return Pose(
                legs: [(CGPoint(x: 30, y: 58), CGPoint(x: 28, y: 70)),
                       (CGPoint(x: 52, y: 56), CGPoint(x: 53, y: 72)),
                       (CGPoint(x: 61, y: 54), CGPoint(x: 64, y: 72))],
                legsAlt: [(CGPoint(x: 30, y: 58), CGPoint(x: 28, y: 70)),
                          (CGPoint(x: 52, y: 56), CGPoint(x: 53, y: 72)),
                          (CGPoint(x: 61, y: 54), CGPoint(x: 64, y: 72))],
                kicksDust: false,
                tail: (CGPoint(x: 18, y: 48), CGPoint(x: 6, y: 52), CGPoint(x: 8, y: 60)),
                bodyCenter: CGPoint(x: 42, y: 47), bodyRadii: CGSize(width: 24, height: 16),
                headCenter: CGPoint(x: 74, y: 36),
                ear: (CGPoint(x: 68, y: 23), CGPoint(x: 53, y: 29), CGPoint(x: 55, y: 48),
                      CGPoint(x: 63, y: 56), CGPoint(x: 71, y: 40)),
                muzzleCenter: CGPoint(x: 94, y: 42), noseCenter: CGPoint(x: 101, y: 39),
                eyeArc: (CGPoint(x: 79, y: 33), CGPoint(x: 83, y: 37), CGPoint(x: 87, y: 33)),
                eyeDot: nil,
                tongue: (CGPoint(x: 94, y: 49), CGPoint(x: 96, y: 58), CGPoint(x: 89, y: 59)),
                collar: (CGPoint(x: 34, y: 35), CGPoint(x: 37, y: 47), CGPoint(x: 35, y: 57)),
                tagCenter: CGPoint(x: 35.5, y: 59),
                sweat: [(CGPoint(x: 60, y: 12), 2.8), (CGPoint(x: 68, y: 5), 2.1)])
        }
    }

    // MARK: Drawing

    private static func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func quad(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: from)
        path.curve(to: to, controlPoint1: control, controlPoint2: control)  // quadratic as cubic
        return path
    }

    private static func oval(_ center: CGPoint, _ radii: CGSize) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radii.width, y: center.y - radii.height,
                                    width: radii.width * 2, height: radii.height * 2))
    }

    private static func filled(_ path: NSBezierPath, _ fill: NSColor, outline: CGFloat = 3) {
        fill.setFill()
        path.fill()
        stroke(path, ink, outline)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// How fast the stride cycles, per mood. A tired dog running at the same cadence
    /// as a fresh one would say the opposite of what the pose says.
    static func strideDuration(_ mood: DogMood) -> TimeInterval {
        switch mood {
        // Spread wide on purpose. A sprint and a trudge have to be told apart at a
        // glance, and 0.85 vs 1.10 was a difference nobody could see.
        case .energetic: return 0.50   // sprint
        case .steady:    return 0.85
        case .tired:     return 1.70   // trudging
        // Not zero: the dog has stopped running, but a completely frozen image reads
        // as a broken app rather than a resting animal. Two sitting poses swapped
        // this slowly is a shift of weight, not a run.
        case .spent:     return 2.60
        }
    }

    /// Draws the dog into the current context, scaled to fit `rect` while keeping
    /// the design proportions. `scale` is derived rather than passed so callers
    /// cannot accidentally stretch it.
    ///
    /// `phase` runs 0..<1 through one stride. At 0 the drawing is identical to the
    /// static art, so nothing depends on being animated -- the notification PNG and
    /// the offscreen sheets pass nothing and get the pose that was designed.
    static func draw(mood: DogMood, in rect: NSRect, phase: CGFloat = 0) {
        guard let context = NSGraphicsContext.current else { return }
        var p = pose(for: mood)

        // Eased back and forth rather than sawtooth: a leg that snaps back to the
        // start of the stride reads as a glitch, not a gait.
        let swing = (1 - cos(phase * 2 * .pi)) / 2
        if p.legsAlt.count == p.legs.count {
            p.legs = zip(p.legs, p.legsAlt).map { (lerp($0.0, $1.0, swing), lerp($0.1, $1.1, swing)) }
        }
        // The body rises as the legs gather -- the bounce is what sells it as running
        // rather than as legs waving under a stationary body.
        let bob = (mood == .spent ? 0.6 : 1.8) * (swing - 0.5)
        p.bodyCenter.y += bob
        p.headCenter.y += bob
        p.muzzleCenter.y += bob
        p.noseCenter.y += bob
        p.tagCenter.y += bob

        let factor = min(rect.width / box.width, rect.height / box.height)
        let drawn = NSSize(width: box.width * factor, height: box.height * factor)

        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX + (rect.width - drawn.width) / 2,
                             yBy: rect.minY + (rect.height + drawn.height) / 2)
        transform.scaleX(by: factor, yBy: -factor)   // SVG's y-down, once, here
        transform.translateX(by: contentOffset.x, yBy: contentOffset.y)
        transform.concat()

        // Order matters and mirrors the SVG: legs and tail sit behind the body, and
        // the ear goes on *after* the head or the head circle paints over it.
        for (a, b) in p.legs {
            let leg = NSBezierPath()
            leg.move(to: a); leg.line(to: b)
            stroke(leg, ink, 6.5)
        }
        stroke(quad(p.tail.from, p.tail.control, p.tail.to), furDark, 7)

        filled(oval(p.bodyCenter, p.bodyRadii), fur)
        filled(oval(p.headCenter, CGSize(width: 17, height: 17)), fur)

        let ear = NSBezierPath()
        ear.move(to: p.ear.root)
        ear.curve(to: p.ear.mid, controlPoint1: p.ear.c1, controlPoint2: p.ear.c1)
        ear.curve(to: p.ear.back, controlPoint1: p.ear.c2, controlPoint2: p.ear.c2)
        ear.close()
        filled(ear, furDark, outline: 3)

        filled(oval(p.muzzleCenter, CGSize(width: 12, height: 8.5)), fur)
        ink.setFill()
        oval(p.noseCenter, CGSize(width: 3.4, height: 3.4)).fill()

        if let arc = p.eyeArc { stroke(quad(arc.from, arc.control, arc.to), ink, 3) }
        if let dot = p.eyeDot { ink.setFill(); oval(dot, CGSize(width: 3, height: 3)).fill() }
        if let t = p.tongue { stroke(quad(t.from, t.control, t.to), collar, 5) }

        stroke(quad(p.collar.from, p.collar.control, p.collar.to), collar, 6)
        let tagPath = oval(p.tagCenter, CGSize(width: 3.6, height: 3.6))
        tag.setFill(); tagPath.fill(); stroke(tagPath, ink, 2)

        for (center, radius) in p.sweat {
            sweat.setFill()
            oval(center, CGSize(width: radius, height: radius)).fill()
        }

        // Dust behind the rear paw. Two puffs offset in the cycle so there is always
        // one forming and one fading, which is what makes the ground feel like it is
        // being pushed against rather than hovered over.
        if p.kicksDust, let rear = p.legs.first {
            for offset in [CGFloat(0), 0.5] {
                let life = (phase + offset).truncatingRemainder(dividingBy: 1)
                let radius = 2.6 + life * 6.5
                let center = CGPoint(x: rear.1.x - 5 - life * 17, y: rear.1.y + 1 - life * 5)
                furDark.withAlphaComponent(0.52 * (1 - life)).setFill()
                oval(center, CGSize(width: radius, height: radius)).fill()
            }
        }

        context.restoreGraphicsState()
    }

    /// One stride, pre-rasterised.
    ///
    /// Re-stroking twenty-odd paths twelve times a second measured at ~2.4% CPU for a
    /// single small dog. The drawing never changes between cycles, so it only has to
    /// happen once: after that a frame is a bitmap blit, which is the difference
    /// between an animation you can leave running and one you feel in the battery.
    ///
    /// Keyed by mood and by rounded pixel size, because a cache that missed on every
    /// sub-pixel resize would quietly do the expensive thing forever.
    private static var frameCache: [String: [NSImage]] = [:]
    static let frameCount = 10

    /// Frames supplied as image files, if the bundle has any.
    ///
    /// Drawing the dog in code was a way to have a dog at all, not a commitment to
    /// drawing it forever -- and character art is a taste problem that a coordinate
    /// nudge is a bad tool for. A file anyone can replace beats a bezier path only
    /// its author can argue with, so if `Resources/dog/<mood>-1.png` exists it wins
    /// and the drawn version becomes the fallback for when it doesn't.
    ///
    /// Frames are numbered from 1 and read until one is missing, so dropping in four
    /// files or twenty-four needs no code change. A mood with a single file simply
    /// doesn't animate.
    private static func numberedFrames(_ directory: URL, _ stem: String) -> [NSImage] {
        var images: [NSImage] = []
        var index = 1
        while let image = NSImage(contentsOf: directory.appendingPathComponent("\(stem)-\(index).png")) {
            images.append(image)
            index += 1
        }
        return images
    }

    private static func bundledFrames(for mood: DogMood) -> [NSImage]? {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("dog") else { return nil }

        // Per-mood art wins when it exists: a tired dog that also *looks* tired says
        // more than a fresh one played slowly.
        let perMood = numberedFrames(directory, "\(mood)")
        if !perMood.isEmpty { return perMood }

        // Otherwise one shared run cycle, and the mood only changes how fast it plays.
        // This is the cheap option deliberately -- seven drawings instead of
        // twenty-four, and speed alone already separates a sprint from a trudge.
        if mood == .spent, let standing = NSImage(contentsOf: directory.appendingPathComponent("stand.png")) {
            return [standing]
        }
        let shared = numberedFrames(directory, "run")
        return shared.isEmpty ? nil : shared
    }

    static func frames(mood: DogMood, size: NSSize) -> [NSImage] {
        let key = "\(mood)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        if let cached = frameCache[key] { return cached }

        if let supplied = bundledFrames(for: mood) {
            frameCache[key] = supplied
            return supplied
        }
        let built = (0..<frameCount).map { index -> NSImage in
            let image = NSImage(size: size, flipped: false) { rect in
                draw(mood: mood, in: rect, phase: CGFloat(index) / CGFloat(frameCount))
                return true
            }
            image.isTemplate = false
            return image
        }
        frameCache[key] = built
        return built
    }

    /// Whether the art is coming from files rather than from `draw`. Callers that
    /// composite the dog onto something (the notification attachment) need to know,
    /// because supplied art already carries its own margins.
    static var usesSuppliedArt: Bool { bundledFrames(for: .steady) != nil }

    static func image(mood: DogMood, height: CGFloat, phase: CGFloat = 0) -> NSImage {
        let size = NSSize(width: (box.width / box.height) * height, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(mood: mood, in: rect, phase: phase)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A paw print, used to mark where a limit sits on its track. Small enough that
    /// it has to be shape-only -- no outline survives at 14pt.
    static func pawPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        // Pad, then four toes above it.
        path.appendOval(in: NSRect(x: x + w * 0.25, y: y, width: w * 0.5, height: h * 0.42))
        let toes: [(CGFloat, CGFloat, CGFloat)] = [
            (0.22, 0.58, 0.115), (0.42, 0.74, 0.115), (0.64, 0.72, 0.115), (0.80, 0.55, 0.105),
        ]
        for (cx, cy, r) in toes {
            path.appendOval(in: NSRect(x: x + w * (cx - r), y: y + h * (cy - r * 1.6),
                                       width: w * r * 2, height: h * r * 2.2))
        }
        return path
    }
}
