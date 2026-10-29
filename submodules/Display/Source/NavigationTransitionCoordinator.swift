import UIKit
import AppBundle
import AsyncDisplayKit

enum NavigationTransition {
    case Push
    case Pop
}

private let shadowWidth: CGFloat = 16.0

private func generateShadow() -> UIImage? {
    return generateImage(CGSize(width: 16.0, height: 1.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(UIColor.black.cgColor)
        context.setShadow(offset: CGSize(), blur: 16.0, color: UIColor(white: 0.0, alpha: 0.5).cgColor)
        context.fill(CGRect(origin: CGPoint(x: size.width, y: 0.0), size: CGSize(width: 16.0, height: 1.0)))
    })
}

private let shadowImage = generateShadow()

public protocol CustomNavigationTransitionNode: ASDisplayNode {
    func setup(topNavigationBar: NavigationBar, bottomNavigationBar: NavigationBar)
    func update(containerSize: CGSize, fraction: CGFloat, transition: ContainedViewLayoutTransition)
    func restore()
}

final class NavigationTransitionCoordinator {
    private var _progress: CGFloat = 0.0
    var progress: CGFloat {
        get {
            return self._progress
        }
    }
    
    private let container: NavigationContainer
    private let transition: NavigationTransition
    let isInteractive: Bool
    let isFlat: Bool
    private(set) var topNode: ASDisplayNode
    let bottomNode: ASDisplayNode
    private let topNavigationBar: NavigationBar?
    private let bottomNavigationBar: NavigationBar?
    private let dimNode: ASDisplayNode
    private let shadowNode: ASImageNode
    private let customTransitionNode: CustomNavigationTransitionNode?
    
    private var topNodeInitialParameters: (clipsToBounds: Bool, cornerRadius: CGFloat)?
    
    private let inlineNavigationBarTransition: Bool
    
    private(set) var animatingCompletion = false

    /// Non-nil while the transition is parked at an intermediate detent instead of having been
    /// completed or cancelled. Both controllers stay in the hierarchy and stay interactive.
    private(set) var restingProgress: CGFloat?

    var isResting: Bool {
        return self.restingProgress != nil
    }

    /// Whether this transition has come to rest at least once. Sticky for its whole life.
    ///
    /// It marks the point where the page below stops being "the page behind" and becomes a page
    /// the user is looking at. After that the parallax only comes back if they go back to the
    /// controller on top.
    private(set) var hasRested: Bool = false

    /// 0 = the node below lags behind with the usual parallax, 1 = it has caught up to its own
    /// position. At `.peek` the column that stays visible is the *leading* edge of the controller
    /// below, and with the parallax still applied its first ~90 points would be off screen — the
    /// avatars would be exactly the part you cannot see.
    ///
    /// It is also the preview: `setParallaxSettled` is driven live from the release predicate
    /// while the finger is still down, so the user sees where a release would land before
    /// committing, and sees it change if they change their mind.
    private let parallaxSettleSpring = NavigationSpringScalar()
    private var parallaxSettleTarget: CGFloat = 0.0
    /// Everything the preview does is a function of this one number, so the parts cannot drift
    /// apart: the wallpaper's blur, how far it is grown to hide the blur's soft edge, and how much
    /// of the page's own chrome is left.
    /// Lands an interactive transition on its detent.
    ///
    /// Integrated here rather than handed to Core Animation, for one reason: `updateProgress`
    /// writes `_progress` immediately and then lets CA move the frames, so during a CA landing
    /// `progress` reports the destination while the screen is still somewhere else. Anything that
    /// reads it mid-flight — the gesture taking the transition back, the list deriving an avatar
    /// scale from it — gets a lie and jumps. Driving it per frame makes the number true at every
    /// instant, and makes the landing itself interruptible.
    ///
    /// Only for interactive transitions. Scripted push/pop keeps the existing CA path, so nothing
    /// else in the app changes.
    private let progressSpring = NavigationSpringScalar()
    private var progressSpringCompletion: (() -> Void)?

    private let peekPresenceSpring = NavigationSpringScalar()
    private weak var peekBlurNode: ASDisplayNode?
    /// Told the presence every frame so it can fade its own chrome.
    var peekPresenceUpdated: ((CGFloat) -> Void)?
    private var parallaxSettle: CGFloat {
        return self.parallaxSettleSpring.value
    }
    private var currentCompletion: (() -> Void)?
    private var didUpdateProgress: ((CGFloat, ContainedViewLayoutTransition, CGRect, CGRect) -> Void)?
    
    private var frameRateLink: SharedDisplayLinkDriver.Link?
    
    init(transition: NavigationTransition, isInteractive: Bool, isFlat: Bool, container: NavigationContainer, topNode: ASDisplayNode, topNavigationBar: NavigationBar?, bottomNode: ASDisplayNode, bottomNavigationBar: NavigationBar?, screenCornerRadius: CGFloat, didUpdateProgress: ((CGFloat, ContainedViewLayoutTransition, CGRect, CGRect) -> Void)? = nil) {
        self.transition = transition
        self.isInteractive = isInteractive
        self.isFlat = isFlat
        self.container = container
        self.didUpdateProgress = didUpdateProgress
        self.topNode = topNode
        self.bottomNode = bottomNode
        self.topNavigationBar = topNavigationBar
        self.bottomNavigationBar = bottomNavigationBar
        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor.black
        // The dim covers everything left of the top node, which at a resting detent is exactly the
        // column the user is meant to be able to touch. It is decoration, never a target.
        self.dimNode.isUserInteractionEnabled = false
        self.shadowNode = ASImageNode()
        self.shadowNode.displaysAsynchronously = false
        self.shadowNode.image = shadowImage
        
        if let topNavigationBar = topNavigationBar, let bottomNavigationBar = bottomNavigationBar {
            if let customTransitionNode = topNavigationBar.makeCustomTransitionNode?(bottomNavigationBar, isInteractive) {
                self.inlineNavigationBarTransition = false
                customTransitionNode.setup(topNavigationBar: topNavigationBar, bottomNavigationBar: bottomNavigationBar)
                self.customTransitionNode = customTransitionNode
            } else if let customTransitionNode = bottomNavigationBar.makeCustomTransitionNode?(topNavigationBar, isInteractive) {
                self.inlineNavigationBarTransition = false
                customTransitionNode.setup(topNavigationBar: topNavigationBar, bottomNavigationBar: bottomNavigationBar)
                self.customTransitionNode = customTransitionNode
            } else if !topNavigationBar.isHidden, !bottomNavigationBar.isHidden, topNavigationBar.canTransitionInline, bottomNavigationBar.canTransitionInline, topNavigationBar.item?.leftBarButtonItem == nil {
                var topFrame = topNavigationBar.view.convert(topNavigationBar.bounds, to: container.view)
                var bottomFrame = bottomNavigationBar.view.convert(bottomNavigationBar.bounds, to: container.view)
                topFrame.origin.x = 0.0
                bottomFrame.origin.x = 0.0
                self.inlineNavigationBarTransition = true
                self.customTransitionNode = nil
            } else {
                self.inlineNavigationBarTransition = false
                self.customTransitionNode = nil
            }
        } else {
            self.inlineNavigationBarTransition = false
            self.customTransitionNode = nil
        }
        
        switch transition {
        case .Push:
            self.container.addSubnode(topNode)
        case .Pop:
            if topNode.supernode == self.container {
                self.container.insertSubnode(bottomNode, belowSubnode: topNode)
            } else {
                self.container.addSubnode(topNode)
            }
        }
        
        if !self.isFlat {
            self.container.insertSubnode(self.dimNode, belowSubnode: topNode)
            self.container.insertSubnode(self.shadowNode, belowSubnode: self.dimNode)
            
            if screenCornerRadius > 0.0 {
                self.topNodeInitialParameters = (topNode.clipsToBounds, topNode.cornerRadius)
                if #available(iOS 13.0, *) {
                    topNode.layer.cornerCurve = .continuous
                }
                topNode.clipsToBounds = true
                topNode.cornerRadius = screenCornerRadius
            }
        }
        if let customTransitionNode = self.customTransitionNode {
            self.container.addSubnode(customTransitionNode)
        }
        
        self.maybeCreateNavigationBarTransition()
        self.updateProgress(0.0, transition: .immediate, completion: {})
        
        self.frameRateLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { _ in })

        self.parallaxSettleSpring.stiffness = 230.0
        self.parallaxSettleSpring.dampingRatio = 0.86
        self.peekPresenceSpring.stiffness = 230.0
        self.peekPresenceSpring.dampingRatio = 1.0
        self.progressSpring.stiffness = NavigationInteractiveDetentMetrics.landingStiffness
        self.progressSpring.dampingRatio = NavigationInteractiveDetentMetrics.landingDamping
        self.progressSpring.onChange = { [weak self] value in
            self?.updateProgress(value, transition: .immediate, completion: {})
        }
        self.progressSpring.onSettle = { [weak self] in
            guard let strongSelf = self, let completion = strongSelf.progressSpringCompletion else {
                return
            }
            strongSelf.progressSpringCompletion = nil
            completion()
        }

        self.peekPresenceSpring.onChange = { [weak self] value in
            self?.applyPeekPresence(value)
        }

        self.parallaxSettleSpring.onChange = { [weak self] _ in
            // The progress spring lays everything out from the current parallax value anyway, so
            // while both are running only one of them needs to do it.
            if self?.progressSpring.isAnimating == true {
                return
            }
            guard let strongSelf = self else {
                return
            }
            // Re-lay out from the spring's current value. `.immediate` because the spring *is* the
            // animation — handing this to Core Animation as well would be two animations fighting
            // over the same frame.
            strongSelf.updateProgress(strongSelf.progress, transition: .immediate, completion: {})
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateProgress(_ progress: CGFloat, transition: ContainedViewLayoutTransition, completion: @escaping () -> Void) {
        self._progress = progress
        
        let position: CGFloat
        switch self.transition {
        case .Push:
            position = 1.0 - progress
        case .Pop:
            position = progress
        }
        
        var dimInset: CGFloat = 0.0
        if let bottomNavigationBar = self.bottomNavigationBar , self.inlineNavigationBarTransition {
            if self.bottomNavigationBar?.isBackgroundVisible == false || self.topNavigationBar?.isBackgroundVisible == false {
                
            } else {
                dimInset = bottomNavigationBar.frame.maxY
            }
        }
        
        let containerSize = self.container.bounds.size
        
        let topFrame = CGRect(origin: CGPoint(x: floorToScreenPixels(position * containerSize.width), y: 0.0), size: containerSize)
        let parallaxOffset = (position - 1.0) * containerSize.width * 0.3 * (1.0 - self.parallaxSettle)
        let bottomFrame = CGRect(origin: CGPoint(x: self.isFlat ? -floorToScreenPixels((1.0 - position) * containerSize.width) : parallaxOffset, y: 0.0), size: containerSize)
        
        var canInvokeCompletion = false
        var hadEarlyCompletion = false
        transition.updateFrame(node: self.topNode, frame: topFrame, completion: { _ in
            if canInvokeCompletion {
                completion()
            } else {
                hadEarlyCompletion = true
            }
        })
        canInvokeCompletion = true
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(x: 0.0, y: dimInset), size: CGSize(width: max(0.0, topFrame.minX + self.container.overflowInset + 62.0), height: self.container.bounds.size.height - dimInset)))
        transition.updateFrame(node: self.shadowNode, frame: CGRect(origin: CGPoint(x: self.dimNode.frame.maxX - shadowWidth, y: dimInset), size: CGSize(width: shadowWidth, height: containerSize.height - dimInset)))
        transition.updateAlpha(node: self.dimNode, alpha: (1.0 - position) * 0.15)
        transition.updateAlpha(node: self.shadowNode, alpha: (1.0 - position) * 0.9)
        
        transition.updateFrame(node: self.bottomNode, frame: bottomFrame)
        
        self.updateNavigationBarTransition(transition: transition)
        
        if let customTransitionNode = self.customTransitionNode {
            customTransitionNode.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: containerSize.width, height: containerSize.height))
            customTransitionNode.update(containerSize: containerSize, fraction: position, transition: transition)
        }
        
        self.didUpdateProgress?(self.progress, transition, topFrame, bottomFrame)
        
        if hadEarlyCompletion {
            completion()
        }
    }
    
    private func updateNavigationBarTransition(transition: ContainedViewLayoutTransition) {
        if let topNavigationBar = self.topNavigationBar, let bottomNavigationBar = self.bottomNavigationBar, self.inlineNavigationBarTransition {
            let position: CGFloat
            switch self.transition {
                case .Push:
                    position = 1.0 - progress
                case .Pop:
                    position = progress
            }
            
            let _ = position
            let _ = topNavigationBar
            let _ = bottomNavigationBar
        }
    }
    
    func maybeCreateNavigationBarTransition() {
        if let topNavigationBar = self.topNavigationBar, let bottomNavigationBar = self.bottomNavigationBar, self.inlineNavigationBarTransition {
            let position: CGFloat
            switch self.transition {
                case .Push:
                    position = 1.0 - progress
                case .Pop:
                    position = progress
            }
            
            let _ = position
            let _ = topNavigationBar
            let _ = bottomNavigationBar
        }
    }
    
    func endNavigationBarTransition() {
        if let topNavigationBar = self.topNavigationBar, let bottomNavigationBar = self.bottomNavigationBar, self.inlineNavigationBarTransition {
            let _ = topNavigationBar
            let _ = bottomNavigationBar
        }
    }
    
    /// Live preview of the release predicate's current answer.
    ///
    /// Runs on a display link rather than off gesture events: the interesting moment is precisely
    /// when the finger *stops*, and a stationary finger produces no `.changed` callbacks to drive
    /// an animation from.
    /// Blur the controller on top while the detent is being predicted.
    ///
    /// Animated by Core Animation rather than driven per frame: the radius is independent of
    /// everything the gesture writes, so nothing here fights `updateProgress`, and a filter whose
    /// value is being rewritten every frame re-renders the blur every frame. Letting CA own the
    /// interpolation means the expensive part happens on the GPU and settles.
    /// Hand `progress` to the spring and let it fly, reporting every frame.
    private func startProgressSpring(to target: CGFloat, velocity: CGFloat, completion: (() -> Void)?) {
        // Seed from where things actually are, not from the model value — they are the same here
        // only because nothing else is animating, and relying on that would be fragile.
        self.progressSpring.reset(to: self.progress)
        self.progressSpringCompletion = completion

        // The gesture reports points per second; the spring lives in progress units.
        let width = self.container.bounds.size.width
        self.progressSpring.animate(to: target, initialVelocity: width > 0.0 ? velocity / width : 0.0)
    }

    func setPeekBlurred(_ blurred: Bool, node: ASDisplayNode?) {
        if self.peekBlurNode !== node {
            // The controller on top was swapped mid-gesture. Leave the old one as we found it and
            // put the new one straight at the current presence — the blur belongs to the *state*,
            // not to the page, so it must not replay a fade on every row the finger crosses.
            self.clearPeekBlur(on: self.peekBlurNode)
            self.peekBlurNode = node
            self.applyPeekPresence(self.peekPresenceSpring.value)
        }
        self.peekPresenceSpring.retarget(to: blurred ? 1.0 : 0.0)
    }

    /// Lay the current presence onto everything that derives from it.
    private func applyPeekPresence(_ presence: CGFloat) {
        self.peekPresenceUpdated?(presence)

        guard let node = self.peekBlurNode else {
            return
        }
        if presence <= 0.0001 {
            self.clearPeekBlur(on: node)
            return
        }

        let radius = presence * NavigationInteractiveDetentMetrics.peekBlurRadius
        if node.layer.filters?.isEmpty ?? true {
            guard let filter = CALayer.blur() else {
                return
            }
            filter.setValue(radius as NSNumber, forKey: "inputRadius")
            node.layer.filters = [filter]
        }
        // Writing the model value rather than handing Core Animation an animation. The spring is
        // the animation, and it has to stay interruptible: flipping the prediction back and forth
        // must reverse from wherever the blur currently is, not restart from a fixed endpoint.
        node.layer.setValue(radius as NSNumber, forKeyPath: "filters.gaussianBlur.inputRadius")

        let shortSide = min(node.bounds.width, node.bounds.height)
        if shortSide > 0.0 {
            let overshoot = radius * NavigationInteractiveDetentMetrics.peekBlurEdgeOvershoot
            let scale = (shortSide + overshoot * 2.0) / shortSide
            node.layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
        }
    }

    private func clearPeekBlur(on node: ASDisplayNode?) {
        guard let node else {
            return
        }
        // An idle filter keeps the layer on an offscreen pass forever.
        node.layer.filters = []
        node.layer.transform = CATransform3DIdentity
    }

    func setParallaxSettled(_ settled: Bool) {
        let target: CGFloat = settled ? 1.0 : 0.0
        // Called every frame of the gesture, so it has to be free when nothing changes. Without
        // this guard `retarget` reaches its settled branch and reports the value again, and the
        // listener lays everything out a second time on every single frame.
        if self.parallaxSettleTarget == target {
            return
        }
        self.parallaxSettleTarget = target
        self.parallaxSettleSpring.retarget(to: target)
    }

    private func stopParallaxSettleAnimation() {
        self.parallaxSettleSpring.stop()
    }

    /// Third sibling of `animateCompletion` and `animateCancel`: spring to `target` and stay there.
    ///
    /// Nothing is torn down — the node below keeps its place in the hierarchy, the navigation bar
    /// transition is left running, and no completion fires. The transition simply stops being in
    /// motion while remaining a transition.
    func animateRest(to target: CGFloat, velocity: CGFloat) {
        self.restingProgress = target
        self.hasRested = true
        self.setParallaxSettled(true)
        self.startProgressSpring(to: target, velocity: velocity, completion: nil)
    }

    /// The user grabbed a resting transition again. Everything is already set up, so this only has
    /// to stop calling it resting. The parallax stays settled: it is a one-way move per gesture,
    /// re-running it on every change of mind would read as the list sliding around under the chat.
    /// Swap the controller on top without disturbing the rest of the transition.
    ///
    /// At a resting detent the controller below is a live source — picking something in it should
    /// change what is on top, the way a detail column behaves, rather than stack onto it. The node
    /// below, the dim, the shadow and the progress all stay exactly as they are.
    func replaceTopNode(_ node: ASDisplayNode, screenCornerRadius: CGFloat) {
        self.restoreTopNodeCorners()
        self.topNodeInitialParameters = nil
        self.topNode = node

        if !self.isFlat {
            if screenCornerRadius > 0.0 {
                self.topNodeInitialParameters = (node.clipsToBounds, node.cornerRadius)
                if #available(iOS 13.0, *) {
                    node.layer.cornerCurve = .continuous
                }
                node.clipsToBounds = true
                node.cornerRadius = screenCornerRadius
            }
            // The new node was added on top of everything; put the decoration back underneath it.
            self.container.insertSubnode(self.dimNode, belowSubnode: node)
            self.container.insertSubnode(self.shadowNode, belowSubnode: self.dimNode)
        }

        self.updateProgress(self.progress, transition: .immediate, completion: {})
    }

    /// Frame of the controller on top, in the container's coordinates. Used to tell a touch on the
    /// parked controller apart from a touch on the column it exposed.
    var topNodeFrame: CGRect {
        return self.topNode.frame
    }

    func beginTakeover() {
        self.restingProgress = nil
        // Hands position *and* velocity back. The finger continues from the speed the landing had
        // reached, instead of restarting from rest.
        self.progressSpring.stop()
        self.progressSpringCompletion = nil
    }

    func animateCancel(_ velocity: CGFloat = 0.0, completion: @escaping () -> ()) {
        self.currentCompletion = completion
        // Leaving the detent, so it is no longer parked — otherwise the gesture could take over a
        // transition that is already animating itself away.
        self.restingProgress = nil
        self.setPeekBlurred(false, node: nil)
        // Spring the parallax back rather than snapping it: with the landing driven per frame
        // there is no Core Animation pass left to smooth a jump in the node below.
        self.setParallaxSettled(false)

        let finish: () -> Void = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            switch strongSelf.transition {
            case .Push:
                strongSelf.topNode.removeFromSupernode()
            case .Pop:
                strongSelf.bottomNode.removeFromSupernode()
            }

            strongSelf.dimNode.removeFromSupernode()
            strongSelf.shadowNode.removeFromSupernode()

            strongSelf.customTransitionNode?.restore()
            strongSelf.customTransitionNode?.removeFromSupernode()

            strongSelf.endNavigationBarTransition()
            strongSelf.restoreTopNodeCorners()

            if let currentCompletion = strongSelf.currentCompletion {
                strongSelf.currentCompletion = nil
                currentCompletion()
            }
        }

        if self.isInteractive {
            self.startProgressSpring(to: 0.0, velocity: velocity, completion: finish)
        } else {
            // A scripted cancel has no finger behind it; leave it on the original path so nothing
            // outside this gesture changes behaviour.
            let distance = self.progress * self.container.bounds.size.width
            let initialVelocity: CGFloat = distance > 0.0 ? abs(velocity / distance) : 0.0
            self.updateProgress(0.0, transition: .animated(duration: 0.4, curve: .customSpring(damping: 124.0, initialVelocity: initialVelocity)), completion: finish)
        }
    }

    func complete() {
        self.animatingCompletion = true
        
        self._progress = 1.0
        
        self.dimNode.removeFromSupernode()
        self.shadowNode.removeFromSupernode()
        
        self.customTransitionNode?.restore()
        self.customTransitionNode?.removeFromSupernode()
        
        self.endNavigationBarTransition()
        
        self.restoreTopNodeCorners()
        
        if let currentCompletion = self.currentCompletion {
            self.currentCompletion = nil
            currentCompletion()
        }
    }
    
    func performCompletion(completion: @escaping () -> ()) {
        self.updateProgress(1.0, transition: .immediate, completion: { [weak self] in
            if let strongSelf = self {
                strongSelf.dimNode.removeFromSupernode()
                strongSelf.shadowNode.removeFromSupernode()
                
                strongSelf.customTransitionNode?.restore()
                strongSelf.customTransitionNode?.removeFromSupernode()
                
                strongSelf.endNavigationBarTransition()
                
                strongSelf.restoreTopNodeCorners()
                
                if let currentCompletion = strongSelf.currentCompletion {
                    strongSelf.currentCompletion = nil
                    currentCompletion()
                }
            }
            completion()
        })
    }
    
    func animateCompletion(_ velocity: CGFloat, completion: @escaping () -> ()) {
        self.animatingCompletion = true
        self.setPeekBlurred(false, node: nil)
        self.stopParallaxSettleAnimation()
        let distance = (1.0 - self.progress) * self.container.bounds.size.width
        self.currentCompletion = completion
        let f = {
            self.dimNode.removeFromSupernode()
            self.shadowNode.removeFromSupernode()
            
            self.customTransitionNode?.restore()
            self.customTransitionNode?.removeFromSupernode()
            
            self.endNavigationBarTransition()
            
            self.restoreTopNodeCorners()
            
            if let currentCompletion = self.currentCompletion {
                self.currentCompletion = nil
                currentCompletion()
            }
        }
        
        if self.isInteractive {
            // Driven per frame so `progress` stays true to the screen while it flies, and so the
            // finger can take the flight back.
            self.startProgressSpring(to: 1.0, velocity: velocity, completion: f)
        } else {
            // Scripted push/pop. Untouched: this path is every other navigation animation in the
            // app, and it has no finger behind it to hand a velocity over from.
            let initialVelocity: CGFloat = distance > 0.0 ? abs(velocity / distance) : 0.0
            self.updateProgress(1.0, transition: .animated(duration: 0.4, curve: .customSpring(damping: 124.0, initialVelocity: initialVelocity)), completion: {
                f()
            })
        }
    }
    
    private func restoreTopNodeCorners() {
        guard let (clipsToBounds, cornerRadius) = self.topNodeInitialParameters else {
            return
        }
        if #available(iOS 13.0, *) {
            self.topNode.layer.cornerCurve = .circular
        }
        self.topNode.clipsToBounds = clipsToBounds
        self.topNode.cornerRadius = cornerRadius
    }
}
