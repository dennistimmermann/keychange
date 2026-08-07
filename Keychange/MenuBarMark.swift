import AppKit

/// The Keychange mark, evolved from design-handoff/logo: two equal 4:3 plates (the system Input
/// menu badge ratio) at 80% overlap. The front plate carries the current source's code knocked out
/// to a real hole so template rendering survives; the back plate is the source switched *from* —
/// texture only. On a source change the plates animate a swap (a flip-book of `NSImage`s, since
/// status item labels can't run SwiftUI animations).
///
/// Drawn rather than shipped as an asset: the shapes scale exactly, and a template image needs no
/// light/dark variants — AppKit inverts it and applies its own opacity.
enum MenuBarMark {

    /// One complete pose of the mark: the code on the front plate, how far the whole mark is
    /// dimmed (0 on, 1 switched off), and the badge saying why it stopped.
    ///
    /// The code stays legible at every value of `dim`: switched off is still a state you read the
    /// current layout from, and saying what the layout is remains the mark's job. A badge says
    /// *why* it stopped; nil is the user flipping the master switch off, which stays unbadged
    /// — a glyph means something happened to you, not that you did it.
    struct State: Equatable {
        var code: String
        var dim: CGFloat
        var badge: ExternalChangeAction?
    }

    /// The frame `t` (0…1) of the way from `old` to `new`. The code swap slides the plates past
    /// each other, the old glyph fading out by the midpoint before the new one fades in; the dim
    /// interpolates; the badge crossfades. An axis whose endpoints agree is simply held, so any
    /// combination of changes — or none — is the same call, with nothing to branch on.
    static func frame(from old: State, to new: State, progress t: CGFloat) -> NSImage {
        let swap = old.code == new.code ? 1 : t
        let fade = old.badge == new.badge ? 1 : t
        // Both plates dim by the same factor, so the mark keeps its internal contrast on the way
        // down instead of collapsing into one flat shape.
        let ink = 1 - 0.6 * (old.dim + (new.dim - old.dim) * t)
        return markImage { ctx in
            let back = { drawPlate(lerp(frontPlate, backPlate, swap), alpha: (1 - 0.6 * swap) * ink,
                                   code: old.code, glyphFraction: max(0, 1 - 2 * swap), ctx) }
            let front = { drawPlate(lerp(backPlate, frontPlate, swap), alpha: (0.4 + 0.6 * swap) * ink,
                                    code: new.code, glyphFraction: max(0, 2 * swap - 1), ctx) }
            // The plate headed to the front paints on top from the midpoint on.
            if swap < 0.5 { front(); back() } else { back(); front() }
            drawBadge(old.badge, in: frontPlate, fraction: 1 - fade, ctx)
            drawBadge(new.badge, in: frontPlate, fraction: fade, ctx)
        }
    }

    // MARK: - Geometry

    private static let frontPlate = NSRect(x: 1.5, y: 1.4, width: 9.2, height: 6.9)
    private static let backPlate = NSRect(x: 3.34, y: 2.78, width: 9.2, height: 6.9)

    /// Construction spans x 1.5-12.54, y 1.4-10.08 (8.68pt tall), scaled to 18pt tall.
    private static func markImage(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        let k: CGFloat = 18 / 8.68
        let image = NSImage(size: NSSize(width: (11.04 * k).rounded(), height: 18), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: -1.5 * k, y: -1.4 * k)
            ctx.scaleBy(x: k, y: k)
            draw(ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func lerp(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width, height: a.height)
    }

    // MARK: - Drawing

    /// Draws one plate: punches a slightly expanded footprint out of everything below (so a
    /// translucent plate reads as an opaque card with a 0.4pt rim gap instead of blending —
    /// without it, same-brightness plates merge into one blob), fills at `alpha`, then knocks
    /// `glyphFraction` of the code out.
    private static func drawPlate(_ rect: NSRect, alpha: CGFloat, code: String = "",
                                  glyphFraction: CGFloat = 0, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -0.4, dy: -0.4), xRadius: 2.4, yRadius: 2.4).fill()
        ctx.restoreGState()

        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        if !code.isEmpty { knockOut(glyph(code), in: rect, fraction: glyphFraction, ctx) }
    }

    /// Two characters is what the plate fits, so a longer language code is cut to its first two:
    /// `HAW` reads HA, `CKB` reads CK. Chinese is the one case that has to be told apart by script
    /// rather than language — `ZH-HANS` and `ZH-HANT` would both read ZH, and switching between
    /// them would show no change at all.
    private static func glyph(_ text: String) -> NSAttributedString {
        let code: String
        switch text.uppercased() {
        case "ZH-HANS": code = "ZS"
        case "ZH-HANT": code = "ZT"
        default: code = String(text.prefix(2))
        }
        return NSAttributedString(string: code, attributes: [
            .font: NSFont.systemFont(ofSize: 4.8, weight: .bold),
            .kern: -0.1,
        ])
    }

    /// Punches `fraction` of the glyph out of everything drawn so far, centered on the actual
    /// ink: font-metric math (cap height/descender) drifts at this size.
    private static func knockOut(_ text: NSAttributedString, in rect: NSRect,
                                 fraction: CGFloat, _ ctx: CGContext) {
        guard fraction > 0 else { return }
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.setAlpha(fraction)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = .zero
        let ink = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
        CTLineDraw(line, ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The badge that says why the app stopped: full ink on plates that have gone to 40%, over the
    /// mark's bottom-right corner and over whatever of the code is under it — the code is a
    /// two-letter hint, the badge is a state, and a clipped letter still reads.
    ///
    /// Media transport vocabulary, so the pair explains itself: `‖` waits for the layout to match
    /// again, `■` waits for you. Hand-drawn rather than set from a font — no font's pause is a
    /// plain pair of bars at this size, and a glyph with any interior detail turns to mush.
    private static func drawBadge(_ action: ExternalChangeAction?, in plate: NSRect,
                                  fraction: CGFloat, _ ctx: CGContext) {
        guard let action, fraction > 0 else { return }
        let centre = CGPoint(x: plate.maxX - 0.4, y: plate.maxY)

        /// One geometry, asked for twice: `spread` 0 is the ink, `spread` 0.7 the clearance punched
        /// under it, so the outline cannot drift out of step with the shape it surrounds.
        func shape(spread: CGFloat) -> [NSBezierPath] {
            func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
                let grown = rect.insetBy(dx: -spread, dy: -spread)
                return NSBezierPath(roundedRect: grown, xRadius: radius + spread, yRadius: radius + spread)
            }
            guard action == .pause else {
                // The square reads heavier than the two bars at the same height, so it is drawn
                // slightly smaller to keep the pair looking like one family.
                let side: CGFloat = 2.7
                return [rounded(NSRect(x: centre.x - side / 2, y: centre.y - side / 2,
                                       width: side, height: side), 0.3)]
            }
            let width: CGFloat = 0.95, height: CGFloat = 3.2, gap: CGFloat = 0.8
            return [-(gap + width) / 2, (gap + width) / 2].map { offset in
                rounded(NSRect(x: centre.x + offset - width / 2, y: centre.y - height / 2,
                               width: width, height: height), width / 2)
            }
        }

        // The same clearance the plates give each other, so full ink on a 40% plate reads as its
        // own object rather than a darker patch of the card.
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.setAlpha(fraction)
        NSColor.black.setFill()
        shape(spread: 0.7).forEach { $0.fill() }
        ctx.restoreGState()

        NSColor.black.withAlphaComponent(fraction).setFill()
        shape(spread: 0).forEach { $0.fill() }
    }
}
