import Foundation
import UIKit
import QuartzCore

/// Watches touches without ever taking them.
///
/// A transition parked at a detent has to be dismissed by a scroll on the controller on top, while
/// that same scroll still scrolls that controller. Those are two things happening to one finger,
/// not two gestures competing for it — so this recognizer must not compete at all.
///
/// It never leaves `.possible`, and a recognizer that never reaches `.began` takes part in no
/// arbitration: it blocks nothing, nothing has to be told to fail for it, and every existing
/// interaction underneath keeps working untouched. It just watches and reports.
public final class PeekDismissTouchSniffer: UIGestureRecognizer {
    /// Called once per touch sequence, when the finger has moved far enough vertically.
    public var onVerticalMovement: (() -> Void)?
    /// Called at touch-up when the finger barely moved and did not linger.
    public var onTap: (() -> Void)?
    /// Whether this sequence is interesting at all, asked once with the starting location.
    public var shouldTrack: ((CGPoint) -> Bool)?

    private var startLocation: CGPoint?
    private var startTimestamp: Double = 0.0
    private var hasReported = false

    override public init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)

        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
    }

    override public func reset() {
        super.reset()

        self.startLocation = nil
        self.startTimestamp = 0.0
        self.hasReported = false
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        guard touches.count == 1, let touch = touches.first else {
            self.startLocation = nil
            return
        }
        let location = touch.location(in: self.view)
        if self.shouldTrack?(location) == true {
            self.startLocation = location
            self.startTimestamp = CACurrentMediaTime()
        } else {
            self.startLocation = nil
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)

        guard !self.hasReported, let startLocation = self.startLocation, let touch = touches.first else {
            return
        }
        let location = touch.location(in: self.view)
        let offset = CGPoint(x: location.x - startLocation.x, y: location.y - startLocation.y)

        // Vertical only. Horizontal belongs to the interactive transition itself, which is a
        // proper recognizer and does compete for the touch.
        // Clearly vertical, not merely more vertical than horizontal. The first samples of a
        // horizontal swipe are often diagonal, and firing on those dismisses the detent out from
        // under the gesture that was about to drive it.
        if abs(offset.y) > 6.0 && abs(offset.y) > abs(offset.x) * 2.0 {
            self.hasReported = true
            self.onVerticalMovement?()
        }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)

        if !self.hasReported, let startLocation = self.startLocation, let touch = touches.first {
            let location = touch.location(in: self.view)
            let travelled = hypot(location.x - startLocation.x, location.y - startLocation.y)
            if travelled < 10.0 && CACurrentMediaTime() - self.startTimestamp < 0.3 {
                self.hasReported = true
                self.onTap?()
            }
        }
        self.state = .failed
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        self.state = .failed
    }
}
