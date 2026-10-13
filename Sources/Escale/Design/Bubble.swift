import SwiftUI

// A bubble's arrival, shared by the menu over selected text (SelectionMenu.swift)
// and Developer mode's dock (Workbench.swift): a round shape pops, swelling
// past its size with its height trailing its width so it reads as a bubble
// rather than a zoom, and a beat later a capsule is pulled out of it to the
// right. While they touch the two are one shape — blurred together, then cut
// at half their opacity — which is what makes the join stretch and snap like
// a drop.
//
// The springs are computed rather than left to SwiftUI, so both shapes run on
// one clock that its owner stops at `Bubble.total`, about 0.37 s. The values
// are Motion's selection ones, tuned by eye on the selection menu's prototype.

enum Bubble {
    /// From the first frame to the last.
    static let total = max(Motion.selectionPop, Motion.selectionPullDelay + Motion.selectionPull)

    /// How far through the pop, from 0 to 1.
    static func popped(_ elapsed: TimeInterval) -> Double {
        clamp(elapsed / Motion.selectionPop)
    }

    /// The round shape's scale: past 1 on the swell, its height a little behind.
    static func pop(_ elapsed: TimeInterval) -> CGSize {
        let popped = popped(elapsed)
        let spring = spring(Motion.selectionPopBounce)
        let tall = popped >= 1 ? 1 : spring(max(0, popped - Motion.selectionWobble))
        return CGSize(width: spring(popped), height: tall)
    }

    /// How far through the pull, from 0 to 1, before its spring.
    static func pulled(_ elapsed: TimeInterval) -> Double {
        clamp((elapsed - Motion.selectionPullDelay) / Motion.selectionPull)
    }

    /// How far out the capsule is, from 0 to 1, past 1 on the bounce.
    static func pull(_ elapsed: TimeInterval) -> Double {
        spring(Motion.selectionPullBounce)(pulled(elapsed))
    }

    /// The capsule's words, from 0 to 1: they come once it is a third out.
    static func label(_ elapsed: TimeInterval) -> Double {
        clamp((pulled(elapsed) - 0.35) / 0.4)
    }

    /// A damped spring from 0 to 1 over a unit of time, settled at its end.
    /// `bounce` 0 barely overshoots; 1 swings back and forth a few times.
    static func spring(_ bounce: Double) -> (Double) -> Double {
        let damping = max(0.3, min(0.99, 1 - bounce * 0.7))
        let natural = 4.6 / damping
        let damped = natural * (1 - damping * damping).squareRoot()
        return { t in
            guard t < 1 else { return 1 }
            let decay = exp(-damping * natural * t)
            return 1 - decay * (cos(damped * t) + damping * natural / damped * sin(damped * t))
        }
    }

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : (value > 0 ? 1 : 0)
    }
}

/// The round shape and the capsule as one drop: a mask for what is under them.
struct BubbleMask: View {
    let round: CGRect
    var pill: CGRect?

    var body: some View {
        Canvas { context, _ in
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 4))
            context.drawLayer { layer in
                layer.fill(Path(ellipseIn: round), with: .color(.black))
                if let pill {
                    layer.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black))
                }
            }
        }
    }
}
