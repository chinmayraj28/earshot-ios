import SwiftUI

/// The Earshot motif: a point of sound with rings fading out a short way.
///
/// When `animated` is true, rings slowly radiate outward ("listening").
/// With Reduce Motion on, or when `animated` is false, the rings are drawn still.
struct EarshotRings: View {
    var animated = false
    var color: Color = Palette.signal
    var ringCount = 3
    /// Seconds for one ring to travel from the centre to the edge.
    var period: Double = 3.2
    /// Radius of the centre dot as a fraction of the half-width.
    var dotFraction: CGFloat = 0.16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation) { context in
                    Canvas { ctx, size in
                        drawPulse(in: &ctx, size: size, time: context.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                Canvas { ctx, size in drawStill(in: &ctx, size: size) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func drawDot(in ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private func drawStill(in ctx: inout GraphicsContext, size: CGSize) {
        let half = min(size.width, size.height) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dot = half * dotFraction
        drawDot(in: &ctx, center: center, radius: dot)
        for index in 0..<ringCount {
            let t = CGFloat(index + 1) / CGFloat(ringCount)
            let radius = dot + (half - dot) * t * 0.94
            let width = max(1, half * 0.07 * (1 - t * 0.45))
            let opacity = 0.9 - Double(t) * 0.68
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(opacity)), lineWidth: width)
        }
    }

    private func drawPulse(in ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let half = min(size.width, size.height) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dot = half * dotFraction
        // A gentle breath on the centre dot.
        let breath = 1 + 0.05 * sin(time * 2 * .pi / period)
        drawDot(in: &ctx, center: center, radius: dot * breath)
        for index in 0..<ringCount {
            let phase = (time / period + Double(index) / Double(ringCount)).truncatingRemainder(dividingBy: 1)
            let t = CGFloat(phase)
            let radius = dot + (half - dot) * t * 0.96
            let width = max(1, half * 0.065 * (1 - t * 0.6))
            // Fade in quickly, fade out as the ring reaches the edge of earshot.
            let opacity = min(1, Double(t) * 6) * pow(1 - Double(t), 1.4) * 0.9
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(opacity)), lineWidth: width)
        }
    }
}

#Preview("Rings") {
    VStack(spacing: 40) {
        EarshotRings().frame(width: 80)
        EarshotRings(animated: true).frame(width: 200)
    }
    .padding()
    .background(Palette.background)
}
