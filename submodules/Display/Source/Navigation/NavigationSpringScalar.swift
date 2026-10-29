import Foundation
import QuartzCore

/// Spring-animates a single number on a display link.
///
/// Not a view property — a scalar that other geometry is derived from, which is why neither
/// `UIViewPropertyAnimator` nor a `CASpringAnimation` fits: both animate a property and hand back
/// only a fraction, while an interactive gesture needs to read the value *and the velocity* at any
/// moment and continue from there.
///
/// Integrating it directly makes the thing this is for free: taking the animation over mid-flight
/// is `stop()`, which returns position and velocity together, and the finger continues from there
/// with no snap and no rebound.
public final class NavigationSpringScalar {
    /// Called every frame with the new value.
    public var onChange: ((CGFloat) -> Void)?
    /// Called once when the spring comes to rest. `stop()` does not trigger it.
    public var onSettle: (() -> Void)?

    public private(set) var value: CGFloat = 0.0
    /// Change per second, in the same units as `value`.
    public private(set) var velocity: CGFloat = 0.0
    public private(set) var target: CGFloat = 0.0

    /// Undamped angular frequency squared. Higher is snappier.
    public var stiffness: CGFloat = 230.0
    /// 1 = no overshoot. Slightly below 1 gives the small rebound that reads as a physical object
    /// rather than a mechanism.
    public var dampingRatio: CGFloat = 0.86

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0.0

    public init() {
    }

    deinit {
        self.link?.invalidate()
    }

    public var isAnimating: Bool {
        return self.link != nil
    }

    /// Write the value without touching the animation bookkeeping — for the stretch where a finger
    /// owns the number outright.
    public func track(_ newValue: CGFloat) {
        self.value = newValue
        self.onChange?(self.value)
    }

    public func animate(to newTarget: CGFloat, initialVelocity: CGFloat) {
        self.target = newTarget
        self.velocity = initialVelocity
        if self.isSettled {
            self.finish()
            return
        }
        self.startLink()
    }

    /// Change the target while *keeping* the velocity the spring already has. Re-calling
    /// `animate(to:initialVelocity:)` zeroes it, so a target that flips back and forth stutters
    /// once per flip.
    ///
    /// Calling this repeatedly with the same target is safe and necessary: after `track` has moved
    /// the value, the link has to be able to restart even though the target did not change.
    public func retarget(to newTarget: CGFloat) {
        self.target = newTarget
        if self.isSettled {
            self.finish()
            return
        }
        self.startLink()
    }

    /// Place the value without reporting it.
    ///
    /// For handing the number to someone else's animation: reporting it would make the listener
    /// lay out at the new value immediately, and the animation that was about to run would then
    /// start from there instead of from where things actually are on screen — a jump.
    public func reset(to newValue: CGFloat) {
        self.stopLink()
        self.value = newValue
        self.target = newValue
        self.velocity = 0.0
    }

    /// Freeze where it stands and hand the state out, so a gesture can take over. Does *not* fire
    /// `onSettle`.
    @discardableResult
    public func stop() -> (value: CGFloat, velocity: CGFloat) {
        self.stopLink()
        return (self.value, self.velocity)
    }

    private var isSettled: Bool {
        return abs(self.value - self.target) < 0.0005 && abs(self.velocity) < 0.005
    }

    private func acceleration(value: CGFloat, velocity: CGFloat) -> CGFloat {
        let omega = self.stiffness.squareRoot()
        return -self.stiffness * (value - self.target) - 2.0 * self.dampingRatio * omega * velocity
    }

    private func startLink() {
        if self.link != nil {
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(self.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        self.lastTimestamp = 0.0
    }

    private func stopLink() {
        self.link?.invalidate()
        self.link = nil
    }

    private func finish() {
        self.stopLink()
        self.value = self.target
        self.velocity = 0.0
        self.onChange?(self.value)
        self.onSettle?()
    }

    @objc private func step(_ link: CADisplayLink) {
        if self.lastTimestamp <= 0.0 {
            self.lastTimestamp = link.timestamp
            return
        }
        // One long frame integrated in a single step blows the spring up, so clamp the elapsed
        // time first and then walk it in fixed small steps.
        let elapsed = min(link.timestamp - self.lastTimestamp, 1.0 / 20.0)
        self.lastTimestamp = link.timestamp

        let substep: CGFloat = 1.0 / 240.0
        var remaining = CGFloat(elapsed)
        while remaining > 0.0 {
            let dt = min(substep, remaining)
            remaining -= dt
            self.velocity += self.acceleration(value: self.value, velocity: self.velocity) * dt
            self.value += self.velocity * dt
        }

        if self.isSettled {
            self.finish()
        } else {
            self.onChange?(self.value)
        }
    }
}
