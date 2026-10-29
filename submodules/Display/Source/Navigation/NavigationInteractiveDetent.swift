import Foundation
import UIKit

/// Where an interactive pop can come to rest.
///
/// The interactive pop already drives a single scalar — `NavigationTransitionCoordinator.progress`,
/// 0 = the top controller covers the screen, 1 = it is gone and the one below it is exposed.
/// Everything the transition draws (the top frame, the parallax on the node below, the dim and
/// the edge shadow) is a pure function of it. Adding a resting point in between therefore does
/// not need new geometry, only a third answer to "where does this gesture land".
public enum NavigationInteractiveDetent {
    /// Back to the top controller. The existing `animateCancel` path.
    case cancel
    /// Both controllers stay on screen: a narrow column of the one below, the top one pushed aside.
    case peek
    /// The pop goes through. The existing `animateCompletion` path.
    case complete
}

public enum NavigationInteractiveDetentMetrics {
    /// Width of the column that stays visible at `.peek`, in points.
    ///
    /// Derived from a size rather than stated as a fraction of the screen: the column has to fit
    /// an avatar with equal padding on both sides, and that is a device-independent constraint,
    /// while a fraction drifts with the screen width.
    public static let peekColumnWidth: CGFloat = 92.0

    /// Displacement criterion: the range of `progress` in which `.peek` is a candidate at all.
    /// A single window, no hysteresis — this is a position, the user can see where it is.
    ///
    /// The lower bound has to stay below `peekProgress(width:)` on every supported width, or the
    /// resting point would sit outside its own window.
    public static let peekWindow: ClosedRange<CGFloat> = 0.2 ... 0.8

    /// Momentum criterion, expressed in the same units as `progress`: how much further this flick
    /// would still carry, as a fraction of the screen width.
    ///
    /// Two thresholds, because this is the noisy input. Velocity samples jump frame to frame, and
    /// a single threshold makes the decision flicker while a finger hovers near the boundary.
    /// Revoking the prediction is deliberately harder than granting it.
    ///
    /// At the default deceleration rate 0.4 is about 315 pt/s and 0.6 about 470 pt/s.
    public static let momentumEnterThreshold: CGFloat = 0.4
    public static let momentumExitThreshold: CGFloat = 0.6

    /// UIScrollView's default; the same rate the projection below assumes.
    public static let decelerationRate: CGFloat = 0.998

    /// Vertical travel that takes the gesture over, once `.peek` is already being predicted.
    ///
    /// Half a row: enough that it reads as a vertical intent rather than a wobble, and no more,
    /// because after the takeover the block follows the finger's absolute position anyway — there
    /// is no relationship left between how far it travelled and where it lands.
    public static let verticalLockThreshold: CGFloat = 38.0

    /// Gaussian blur put on the controller on top while the detent is being predicted.
    ///
    /// Part of the preview, alongside the parallax and the haptic: the page is about to stop being
    /// the thing you are reading and become the thing behind the column.
    public static let peekBlurRadius: CGFloat = 12.0

    /// How far past its own edges the blurred layer is grown, as a multiple of the blur radius.
    ///
    /// A Gaussian samples beyond the edge, where there is nothing, so the result fades out over a
    /// band roughly as wide as the radius. Growing the layer pushes that band outside the area
    /// actually shown and the parent clips it — the same result as replicating the edge pixels
    /// before blurring and cropping after, without having to touch pixels.
    public static let peekBlurEdgeOvershoot: CGFloat = 3.0

    /// How far the page's own content shrinks while the detent is being predicted.
    ///
    /// The counterpart to the wallpaper growing: the backdrop spreads out, what was being read
    /// pulls in. Both come off the same number, so they are necessarily one movement rather than
    /// two that happen to coincide.
    public static let peekContentScale: CGFloat = 0.96

    /// The spring that lands an *interactive* transition on its detent.
    ///
    /// Slightly under critical damping: the landing is a displacement, and a displacement that
    /// arrives dead-flat reads as a mechanism rather than as something with weight.
    public static let landingStiffness: CGFloat = 420.0
    public static let landingDamping: CGFloat = 0.9

    /// Avatar scale in the list when the chat is covering it completely.
    ///
    /// The list is a page that something else is sitting on top of, so it is slightly further
    /// away. Scaling only the avatars — the one thing that survives the fade — keeps the column
    /// legible at every point of the gesture.
    public static let peekAvatarScale: CGFloat = 0.75

    /// Below this vertical speed the finger counts as having arrived on a row rather than
    /// passing over it, and the page is allowed to change. Points per second.
    ///
    /// Velocity, not acceleration. A finger sweeping at a steady speed has no acceleration at
    /// all, so acceleration would read the middle of a sweep as "settled" — exactly the rows that
    /// must be skipped. Acceleration is also a second derivative of sampled touches, which makes
    /// its noise the square of the noise in the positions.
    ///
    /// Set low deliberately. Opening a chat blocks the main thread for about 90 ms (measured;
    /// median of the stalls during a drag, worst 132 ms), which at 120 Hz is eleven frames in
    /// which *nothing* moves — not the block, not even touch delivery. So every switch is
    /// expensive enough that it should only happen when the finger has genuinely stopped, not
    /// merely slowed.
    public static let peekDragCommitVelocity: CGFloat = 90.0

    // MARK: The selection block's jelly

    /// Each edge of the block has its own spring. The edge in the direction of travel is stiffer
    /// than the one trailing it, so the block stretches while it moves and springs back when it
    /// lands — the deformation is the lag between two springs, not an animation of its own.
    public static let highlightEdgeStiffnessLeading: CGFloat = 420.0
    public static let highlightEdgeStiffnessFollowing: CGFloat = 190.0
    public static let highlightEdgeDamping: CGFloat = 0.7

    /// The sides, which squash by an amount taken from how far the vertical springs are behind.
    public static let highlightSideStiffness: CGFloat = 300.0
    public static let highlightSideDamping: CGFloat = 0.55
    public static let highlightSideSquash: CGFloat = 9.0

    /// How far the block leans past the row towards the finger, as a fraction of a row.
    ///
    /// This is what gives the movement its detents: the target is the row's own position plus a
    /// small fraction of the distance from the row's centre to the finger, so the block sits on
    /// rows but acknowledges where the finger actually is.
    public static let highlightRowLeanFactor: CGFloat = 0.1

    // MARK: Switching the chat in place
    //
    // Tuned in a standalone prototype, where a change costs twenty seconds instead of seven
    // minutes. Everything here was arrived at by trying it, not by reasoning about it.

    /// How far the outgoing and incoming histories travel, as a fraction of the screen.
    ///
    /// A fraction, not the whole screen as the stock call uses: the two chats are adjacent rows
    /// in a list, not two pages in a stack, and a full-screen throw says something much larger
    /// happened than did.
    public static let chatSwitchTravel: CGFloat = 0.15

    /// How far each history shrinks on its way out, and grows on its way in.
    public static let chatSwitchScale: CGFloat = 0.85

    /// Blur each history picks up as it leaves and sheds as it arrives.
    public static let chatSwitchBlurRadius: CGFloat = 20.0

    /// Both halves run for this long, at the same time.
    ///
    /// *At the same time* is the point. Playing them one after the other was tried and is wrong:
    /// the two histories are then never adjacent, there is a moment where neither is in place, and
    /// it reads as neither a push nor a dissolve. Run together, the incoming leading edge stays
    /// against the outgoing trailing edge and the pair moves like one strip.
    public static let chatSwitchDuration: Double = 0.4

    /// Telegram's own curve, lifted from the fallback its `.spring` lands on at durations that
    /// match neither of its spring fast paths — which is where the stock 0.4 s call ends up. The
    /// second control point sits at (0.125, 1.0), so most of the travel is over early and the
    /// tail is a long settle.
    public static let chatSwitchCurve: (Float, Float, Float, Float) = (0.380, 0.700, 0.125, 1.000)

    public static func peekProgress(width: CGFloat) -> CGFloat {
        guard width > 0.0 else {
            return 0.0
        }
        return max(0.0, min(1.0, peekColumnWidth / width))
    }

    /// How far a flick at this velocity would still travel before friction stops it (WWDC18).
    public static func projectedDistance(velocity: CGFloat, decelerationRate: CGFloat = decelerationRate) -> CGFloat {
        guard decelerationRate > 0.0, decelerationRate < 1.0 else {
            return 0.0
        }
        return (velocity / 1000.0) * decelerationRate / (1.0 - decelerationRate)
    }

    public static func momentum(velocity: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0.0 else {
            return 0.0
        }
        return projectedDistance(velocity: velocity) / width
    }
}

/// Where a release at `progress` with `velocity` lands.
///
/// Uses the velocity projection rather than a bare displacement threshold: the question is where
/// this finger is headed, so releasing slowly in the middle naturally lands where it already is —
/// which is exactly the "stop here, do not finish the transition" behaviour.
///
/// Takes `isPeekPending` (its own previous answer) so the momentum hysteresis has something to
/// hang on. It stays a pure function: the state lives in the caller, so this can be asserted
/// without a running UI.
public func navigationInteractiveDetent(
    progress: CGFloat,
    velocity: CGFloat,
    width: CGFloat,
    isPeekPending: Bool
) -> NavigationInteractiveDetent {
    guard width > 0.0 else {
        return .cancel
    }

    let momentum = NavigationInteractiveDetentMetrics.momentum(velocity: velocity, width: width)

    // Two independent criteria. Position is a plain window; only momentum gets the hysteresis,
    // because only momentum is noisy.
    let momentumLimit = isPeekPending
        ? NavigationInteractiveDetentMetrics.momentumExitThreshold
        : NavigationInteractiveDetentMetrics.momentumEnterThreshold
    if NavigationInteractiveDetentMetrics.peekWindow.contains(progress), abs(momentum) < momentumLimit {
        return .peek
    }

    // Not peek, so the flick decides the direction. With nothing to read in the flick this
    // degrades to deciding by position alone.
    if progress + momentum < NavigationInteractiveDetentMetrics.peekProgress(width: width) {
        return .cancel
    } else {
        return .complete
    }
}

/// Switches that only exist to take a part of the gesture out of the way while looking at the
/// rest of it. Not features, not persisted in the app's own preferences — `UserDefaults` so a
/// setting survives a relaunch without putting a debug flag into `ExperimentalUISettings`, whose
/// every field has to be threaded through an initialiser, a default and a decoder.
public enum NavigationPeekDebugSettings {
    private static let disableDragChatSwitchKey = "peek.debug.disableDragChatSwitch"

    /// Hold the open chat still while the finger travels the column.
    ///
    /// The block still follows the finger and still lands on a row — only the chat behind it stops
    /// being re-pointed. Lets the material and the springs be watched without the switch's own
    /// motion, and its cost, mixed into what is being looked at.
    public static var disableDragChatSwitch: Bool {
        get {
            return UserDefaults.standard.bool(forKey: NavigationPeekDebugSettings.disableDragChatSwitchKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: NavigationPeekDebugSettings.disableDragChatSwitchKey)
        }
    }
}
