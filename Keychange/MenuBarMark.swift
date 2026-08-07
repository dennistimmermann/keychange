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

    /// The static mark: the current source's code on the front plate.
    static func badge(_ code: String) -> NSImage {
        enableFrame(t: 0, code: code)
    }

    /// The mark for an app that is switched off, `autoDisabled` deciding whether it carries a
    /// pause or stop glyph.
    static func disabled(autoDisabled: ExternalChangeAction?) -> NSImage {
        enableFrame(t: 1, code: "", autoDisabled: autoDisabled)
    }

    /// One frame of the enable/disable transition. t = 0: the enabled badge. t = 1: disabled —
    /// same geometry, front plate dimmed to 40% with the code faded out. No motion, just opacity.
    /// `autoDisabled` fades its mark in as the code fades out; nil is the user flipping the master
    /// switch off, which stays unmarked — a glyph means something happened to you, not that you
    /// did it.
    static func enableFrame(t: CGFloat, code: String,
                            autoDisabled: ExternalChangeAction? = nil) -> NSImage {
        markImage { ctx in
            drawPlate(backPlate, alpha: 0.4, ctx)
            drawPlate(frontPlate, alpha: 1 - 0.6 * t, code: code, glyphFraction: 1 - t, ctx)
            if let autoDisabled { knockOutMark(autoDisabled, in: frontPlate, fraction: t, ctx) }
        }
    }

    /// One frame of the plate swap. t = 0: old code front. t = 1: new code front, which is also
    /// `badge`. The old plate's glyph fades out by the midpoint; the new one fades in after it.
    static func swapFrame(t: CGFloat, from oldCode: String, to newCode: String) -> NSImage {
        markImage { ctx in
            let old = { drawPlate(lerp(frontPlate, backPlate, t), alpha: 1 - 0.6 * t,
                                  code: oldCode, glyphFraction: max(0, 1 - 2 * t), ctx) }
            let new = { drawPlate(lerp(backPlate, frontPlate, t), alpha: 0.4 + 0.6 * t,
                                  code: newCode, glyphFraction: max(0, 2 * t - 1), ctx) }
            // The plate headed to the front paints on top from the midpoint on.
            if t < 0.5 { new(); old() } else { old(); new() }
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

    private static func glyph(_ text: String) -> NSAttributedString {
        // 1-2 characters only; 3+ falls back to the first.
        let code = text.count > 2 ? String(text.prefix(1)) : text
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

    /// Media transport vocabulary, so the pair explains itself: `‖` waits for the layout to match
    /// again, `■` waits for you. Hand-drawn rather than set from a font — no font's pause is a
    /// plain pair of bars at this size, and a glyph with any interior detail turns to mush.
    private static func knockOutMark(_ action: ExternalChangeAction, in rect: NSRect,
                                     fraction: CGFloat, _ ctx: CGContext) {
        guard fraction > 0 else { return }
        let height: CGFloat = 3.4, barWidth: CGFloat = 0.9, gap: CGFloat = 0.9
        // The square reads heavier than the two bars at the same height, so it is drawn
        // slightly smaller to keep the pair looking like one family.
        let stopSide: CGFloat = 2.9
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.setAlpha(fraction)
        NSColor.black.setFill()
        if action == .pause {
            for offset in [-(gap + barWidth) / 2, (gap + barWidth) / 2] {
                NSBezierPath(roundedRect: NSRect(x: rect.midX + offset - barWidth / 2, y: rect.midY - height / 2,
                                                 width: barWidth, height: height),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
        } else {
            NSBezierPath(roundedRect: NSRect(x: rect.midX - stopSide / 2, y: rect.midY - stopSide / 2,
                                             width: stopSide, height: stopSide),
                         xRadius: 0.55, yRadius: 0.55).fill()
        }
        ctx.restoreGState()
    }
}
