import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit

public final class NavigationContainer: ASDisplayNode, ASGestureRecognizerDelegate {
    private final class Child {
        let value: ViewController
        var layout: ContainerViewLayout
        
        init(value: ViewController, layout: ContainerViewLayout) {
            self.value = value
            self.layout = layout
        }
    }
    
    private final class PendingChild {
        enum TransitionType {
            case push
            case pop
        }
        
        let value: Child
        let transitionType: TransitionType
        let transition: ContainedViewLayoutTransition
        let disposable: MetaDisposable = MetaDisposable()
        var isReady: Bool = false
        
        init(value: Child, transitionType: TransitionType, transition: ContainedViewLayoutTransition, update: @escaping (PendingChild) -> Void) {
            self.value = value
            self.transitionType = transitionType
            self.transition = transition
            var localIsReady: Bool?
            self.disposable.set((value.value.ready.get()
            |> filter { $0 }
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                if localIsReady == nil {
                    localIsReady = true
                } else if let strongSelf = self {
                    update(strongSelf)
                }
            }))
            if let _ = localIsReady {
                self.isReady = true
            } else {
                localIsReady = false
            }
        }
        
        deinit {
            self.disposable.dispose()
        }
    }
    
    private final class TopTransition {
        let type: PendingChild.TransitionType
        let previous: Child
        let coordinator: NavigationTransitionCoordinator
        
        init(type: PendingChild.TransitionType, previous: Child, coordinator: NavigationTransitionCoordinator) {
            self.type = type
            self.previous = previous
            self.coordinator = coordinator
        }
    }
    
    private struct State {
        var layout: ContainerViewLayout?
        var canBeClosed: Bool?
        var top: Child?
        var transition: TopTransition?
        var pending: PendingChild?
    }
    
    private let isFlat: Bool
    public private(set) var controllers: [ViewController] = []
    private var state: State = State(layout: nil, canBeClosed: nil, top: nil, transition: nil, pending: nil)
    
    weak var minimizedContainer: MinimizedContainer?
    
    private var ignoreInputHeight: Bool = false
    
    public private(set) var isReady: Bool = false
    public var isReadyUpdated: (() -> Void)?
    public var controllerRemoved: (ViewController) -> Void
    public var requestFilterController: (ViewController) -> Void = { _ in }
    public var keyboardViewManager: KeyboardViewManager? {
        didSet {
        }
    }
    
    public var canHaveKeyboardFocus: Bool = false {
        didSet {
            if self.canHaveKeyboardFocus != oldValue {
                if !self.canHaveKeyboardFocus {
                    self.view.endEditing(true)
                    self.performUpdate(transition: .animated(duration: 0.5, curve: .spring))
                }
            }
        }
    }
    
    public var isInFocus: Bool = false {
        didSet {
            if self.isInFocus != oldValue {
                self.inFocusUpdated(isInFocus: self.isInFocus)
            }
        }
    }
    
    public func inFocusUpdated(isInFocus: Bool) {
        self.state.top?.value.isInFocus = isInFocus
    }
    
    public var overflowInset: CGFloat = 0.0
    
    private var currentKeyboardLeftEdge: CGFloat = 0.0
    private var additionalKeyboardLeftEdgeOffset: CGFloat = 0.0
    
    var statusBarStyle: StatusBarStyle = .Ignore {
        didSet {
        }
    }
    var statusBarStyleUpdated: ((ContainedViewLayoutTransition) -> Void)?
    
    
    
    private var panRecognizer: InteractiveTransitionGestureRecognizer?
    
    public init(isFlat: Bool, controllerRemoved: @escaping (ViewController) -> Void) {
        self.isFlat = isFlat
        self.controllerRemoved = controllerRemoved
        
        super.init()
    }
    
    public override func didLoad() {
        super.didLoad()
        
        let panRecognizer = InteractiveTransitionGestureRecognizer(target: self, action: #selector(self.panGesture(_:)), allowedDirections: { [weak self] _ in
            guard let strongSelf = self else {
                return []
            }
            // A transition parked at an intermediate detent can be grabbed in either direction:
            // right carries on towards the pop, left returns to the top controller. The recognizer
            // fails itself on a disallowed direction, so this is the gate that matters — the
            // delegate never gets a say.
            if let coordinator = strongSelf.state.transition?.coordinator, coordinator.isResting {
                return [.left, .right]
            }
            guard strongSelf.controllers.count > 1 else {
                return []
            }
            return .right
        })
        /*panRecognizer.dynamicEdgeWidth = { [weak self] _ in
            guard let self, let controller = self.controllers.last, let value = controller.interactiveNavivationGestureEdgeWidth else {
                return .constant(16.0)
            }
            return value
        }*/
        if #available(iOS 13.4, *) {
            panRecognizer.allowedScrollTypesMask = .continuous
        }
        panRecognizer.delegate = self.wrappedGestureRecognizerDelegate
        panRecognizer.delaysTouchesBegan = false
        panRecognizer.cancelsTouchesInView = true
        self.panRecognizer = panRecognizer
        self.view.addGestureRecognizer(panRecognizer)

        // Dismissing a parked transition by scrolling the controller on top is a side effect of
        // that scroll, not an alternative to it: the finger keeps scrolling. Hence a sniffer that
        // never reaches `.began` and therefore competes with nothing.
        let sniffer = PeekDismissTouchSniffer(target: nil, action: nil)
        sniffer.shouldTrack = { [weak self] point in
            guard let strongSelf = self else {
                return false
            }
            return strongSelf.isPointOnRestingTopController(point)
        }
        sniffer.onVerticalMovement = { [weak self] in
            self?.dismissRestingTransition()
        }
        self.peekDismissSniffer = sniffer
        self.view.addGestureRecognizer(sniffer)

        // The exposed column needs the opposite split: a vertical drag there scrolls the list and
        // must *not* dismiss anything, while a tap is a choice being made and therefore does.
        //
        // Also non-consuming — the list still has to receive the tap, because for every row but
        // the one already open the tap is what changes the chat.
        let columnSniffer = PeekDismissTouchSniffer(target: nil, action: nil)
        columnSniffer.shouldTrack = { [weak self] point in
            guard let strongSelf = self, strongSelf.isRestingAtDetent else {
                return false
            }
            return !strongSelf.isPointOnRestingTopController(point)
        }
        columnSniffer.onTap = { [weak self] in
            self?.scheduleColumnTapDismissal()
        }
        self.peekColumnSniffer = columnSniffer
        self.view.addGestureRecognizer(columnSniffer)

        // A tap is the opposite case: it has no meaning for the parked controller, so it is taken
        // outright and only dismisses.
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.peekDismissTap(_:)))
        tapRecognizer.delegate = self.wrappedGestureRecognizerDelegate
        tapRecognizer.cancelsTouchesInView = true
        self.peekDismissTapRecognizer = tapRecognizer
        self.view.addGestureRecognizer(tapRecognizer)
        
        /*self.view.disablesInteractiveTransitionGestureRecognizerNow = { [weak self] in
            guard let strongSelf = self else {
                return false
            }
            if strongSelf.state.transition != nil {
                return true
            }
            return false
        }*/
    }
    
    func hasNonReadyControllers() -> Bool {
        if let pending = self.state.pending, !pending.isReady {
            return true
        }
        return false
    }
    
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === self.peekDismissTapRecognizer {
            return self.isPointOnRestingTopController(gestureRecognizer.location(in: self.view))
        }
        if gestureRecognizer == self.panRecognizer, let gestureRecognizer = self.panRecognizer, gestureRecognizer.numberOfTouches == 0 {
            let translation = gestureRecognizer.velocity(in: gestureRecognizer.view)
            if abs(translation.y) > 4.0 && abs(translation.y) > abs(translation.x) * 2.5 {
                return false
            }
            // A parked transition can be grabbed in either direction: right continues towards the
            // pop, left returns to the top controller. The rightward-only test below is for
            // *starting* a pop, where leftward has no meaning.
            if let coordinator = self.state.transition?.coordinator, coordinator.isResting {
                return abs(translation.x) >= 4.0
            }
            if translation.x < 4.0 {
                return false
            }
            if self.controllers.count == 1 {
                return false
            }
            return true
        } else {
            return true
        }
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === self.peekDismissTapRecognizer {
            // Only has anything to claim while a transition is parked; outside that it has to stay
            // completely inert, or it holds every tap in the app pending until it fails.
            if !self.isRestingAtDetent {
                return false
            }
            // A tap on the controller on top means "put this away" and nothing else, so everything
            // tap-like has to wait for this one to fail first. Without that the controller's own
            // tap handling simply wins the race.
            //
            // Pans are excluded: they are how the controller scrolls, and gating them behind a
            // tap's failure would put a delay on the start of every scroll.
            if let _ = otherGestureRecognizer as? UIPanGestureRecognizer {
                return false
            }
            return true
        }
        if let _ = otherGestureRecognizer as? InteractiveTransitionGestureRecognizer {
            return false
        }
        if let _ = otherGestureRecognizer as? UIPanGestureRecognizer {
            return true
        }
        // While parked, the controller on top is live — hit testing lets touches through so it can
        // be scrolled. That also means its own recognizers would react to the first few points of
        // a horizontal swipe before this one claims it, so they have to wait here too.
        if self.isRestingAtDetent {
            return true
        }
        return false
    }
    
    /// Progress the current gesture started from. Zero for a fresh pop; the resting value when the
    /// user grabs a parked transition again, so the translation stays relative instead of snapping.
    private var gestureStartProgress: CGFloat = 0.0

    /// Last answer of the release predicate, fed back into it so its momentum hysteresis has state.
    /// Last answer of the release predicate: *would letting go right now land on the detent.*
    /// Changes every frame, follows velocity, and feeds its own hysteresis.
    private var isPeekPending: Bool = false

    /// Whether the user is *in* the preview — which is a state, not a prediction.
    ///
    /// Entered when the prediction first says so, and left only when the finger leaves the
    /// displacement window. Velocity cannot take it away, because velocity is noisy and the
    /// preview is three large animations: a finger hovering near the threshold made the list,
    /// the blur and the scale flicker in and out together.
    ///
    /// The iPhone home gesture draws the same line — past a certain point the preview stays up
    /// no matter how the hand wobbles, and only position puts it away.
    ///
    /// Visual only. What a release actually does still comes from `isPeekPending`, so a fast
    /// flick still completes the pop even while the preview is showing.
    private var isPeekPreviewLatched: Bool = false

    /// The gesture has stopped steering the transition and is steering the list instead. From here
    /// the horizontal component is ignored entirely and the detent is held.
    private var isVerticalLocked: Bool = false

    /// Whether this particular pair of controllers wants the detent at all. Settled once, when
    /// the gesture starts.
    private var isDetentAvailable: Bool = false

    /// Drives the vertical drag from frames rather than from gesture callbacks.
    ///
    /// A finger that stops produces no further `.changed`, and `velocity(in:)` keeps reporting
    /// whatever it last computed — so the one moment that matters, the finger coming to rest,
    /// is the one moment the gesture never reports. Sampling the position every frame and
    /// differencing it ourselves makes a still finger read as zero, immediately.
    private var verticalLockLink: ConstantDisplayLinkAnimator?
    private var verticalLockLastPoint: CGPoint?
    private var verticalLockLastTimestamp: Double = 0.0

    /// Release happened while the gesture was driving the list, and the chat it picked is still
    /// loading. Collapsing now would animate over a page that is still assembling itself, so the
    /// collapse waits for it to land.
    private var dismissWhenTopLands: Bool = false

    private let peekHapticFeedback = HapticFeedback()
    private var peekDismissSniffer: PeekDismissTouchSniffer?
    private var peekColumnSniffer: PeekDismissTouchSniffer?
    private var columnTapDismissalToken: Int = 0
    private var peekDismissTapRecognizer: UITapGestureRecognizer?

    /// Tell the controller below which controller is currently on top of it, so it can show a
    /// persistent selection for it.
    ///
    /// This channel already exists — `NavigationSplitContainer` feeds it on iPad, which is how the
    /// chat list knows to keep the open chat highlighted there. Nothing fed it in a single column,
    /// because in a single column there is never anything below to show. At a resting detent there
    /// is, so the same path applies.
    ///
    /// `progress` reaches the item node as the highlight's alpha, so passing the prediction's
    /// answer fades the selection in and out along with the rest of the preview.
    /// Whether this point lands on the controller parked on top, as opposed to the column it
    /// exposed. Returns false when nothing is parked.
    private func isPointOnRestingTopController(_ point: CGPoint) -> Bool {
        guard let coordinator = self.state.transition?.coordinator, coordinator.isResting else {
            return false
        }
        return point.x >= coordinator.topNodeFrame.minX
    }

    /// A tap on the exposed column dismisses the detent — but only if nothing else did.
    ///
    /// Tapping any row but the one already open changes the chat, and that path swaps the top
    /// controller, which only works while the transition is still parked. So this has to give it
    /// a moment: if the swap happens it cancels this, and if nothing happens (the row tapped was
    /// the one already open) this fires and the detent closes anyway.
    private func scheduleColumnTapDismissal() {
        self.columnTapDismissalToken += 1
        let token = self.columnTapDismissalToken
        Queue.mainQueue().after(0.1, { [weak self] in
            guard let strongSelf = self, strongSelf.columnTapDismissalToken == token else {
                return
            }
            strongSelf.dismissRestingTransition()
        })
    }

    private func startVerticalLockLink() {
        self.verticalLockLastPoint = self.panRecognizer?.location(in: self.view)
        self.verticalLockLastTimestamp = CACurrentMediaTime()
        if let point = self.verticalLockLastPoint {
            self.updatePeekDrag(at: point, velocityY: 0.0)
        }

        self.verticalLockLink?.invalidate()
        let link = ConstantDisplayLinkAnimator { [weak self] in
            self?.verticalLockTick()
        }
        link.isPaused = false
        self.verticalLockLink = link
    }

    private func stopVerticalLockLink() {
        self.verticalLockLink?.invalidate()
        self.verticalLockLink = nil
        self.verticalLockLastPoint = nil
    }

    private func verticalLockTick() {
        guard self.isVerticalLocked, let recognizer = self.panRecognizer else {
            return
        }
        let point = recognizer.location(in: self.view)
        let now = CACurrentMediaTime()

        var velocityY: CGFloat = 0.0
        if let last = self.verticalLockLastPoint {
            let elapsed = now - self.verticalLockLastTimestamp
            if elapsed > 0.0 {
                velocityY = (point.y - last.y) / CGFloat(elapsed)
            }
        }
        self.verticalLockLastPoint = point
        self.verticalLockLastTimestamp = now

        self.updatePeekDrag(at: point, velocityY: velocityY)
    }

    /// Hand the finger's position to the controller below so it can move its own selection.
    private func updatePeekDrag(at point: CGPoint?, velocityY: CGFloat = 0.0) {
        guard let below = self.state.transition?.previous.value else {
            return
        }
        let subject = below.updateNavigationPeekDrag(point.flatMap { self.view.convert($0, to: nil) }, velocityY: velocityY)
        if let subject {
            // A subject comes back only when the row under the finger actually changed — the
            // list returns nil on every other frame — so this is one click per chat, not per
            // frame. Selection rather than impact: this is the same event a picker fires when
            // it steps a notch, and the semantics should match.
            self.peekHapticFeedback.tap()
            // Re-point the page that is already there instead of opening a new one. No fallback
            // to opening one on purpose: doing that mid-gesture costs ~90 ms of blocked main
            // thread, which is worse than the page simply not changing.
            self.state.top?.value.updateNavigationPeekSubject(subject)
        }
    }

    @objc private func peekDismissTap(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.dismissRestingTransition()
        }
    }

    /// Spring the parked transition back to the controller on top. Not interactive — the finger
    /// that triggered this is busy doing something else.
    private func dismissRestingTransition() {
        guard let currentTransition = self.state.transition, currentTransition.coordinator.isResting else {
            return
        }
        self.isPeekPending = false
        self.updatePeekSelection(false, transition: .animated(duration: 0.2, curve: .easeInOut))
        currentTransition.coordinator.beginTakeover()
        currentTransition.coordinator.animateCancel(completion: { [weak self] in
            guard let strongSelf = self, let top = strongSelf.state.top, let transition = strongSelf.state.transition else {
                return
            }
            strongSelf.state.transition = nil
            top.value.viewDidAppear(true)
            transition.previous.value.viewDidDisappear(true)
        })
    }

    /// Whether a transition is parked at an intermediate detent right now.
    public var isRestingAtDetent: Bool {
        return self.state.transition?.coordinator.isResting ?? false
    }

    /// Re-point the chat on top at `subject`, then put the detent away.
    ///
    /// The vertical drag already does exactly this on every row it crosses. A tap is the same
    /// choice made in one step, so it comes here rather than going through navigation: that path
    /// builds a second controller — about 90 ms of blocked main thread — and has nowhere to carry
    /// the direction the block travelled, so the chat cut instead of moved.
    ///
    /// Returns false when nothing is parked or the page on top cannot be re-pointed, so the
    /// caller can fall back to opening the chat the ordinary way.
    public func requestPeekSubject(_ subject: Any) -> Bool {
        guard let currentTransition = self.state.transition,
              currentTransition.coordinator.isResting,
              !currentTransition.coordinator.animatingCompletion,
              let top = self.state.top?.value else {
            return false
        }
        guard top.updateNavigationPeekSubject(subject) else {
            return false
        }
        // Deliberately no `updatePeekSelection` here. That re-reads the identity off the page on
        // top, and the switch it was just handed has not necessarily published it yet — so the
        // block would jump back to the previous row for the length of the collapse. The column
        // moved its own block when it built the subject; it knows which row was chosen.
        //
        // Deferred for the same reason the navigation path defers: this runs inside a touch
        // handler whose remaining work still expects to find the transition in place, and the
        // collapse eventually clears it.
        Queue.mainQueue().justDispatch { [weak self] in
            self?.dismissRestingTransition()
        }
        return true
    }

    /// Whether opening something should swap what is on top instead of stacking onto it.
    ///
    /// Deliberately *not* "is parked right now". Picking a chat starts a load, and the load can
    /// still be in flight when the finger lifts — by which time the detent is already collapsing
    /// and `isResting` is false, so the arriving controller would be pushed on top of the one it
    /// was supposed to replace. Having rested at all is the right question: it means the page
    /// below was being used as a source, whatever the transition is doing by the time the answer
    /// comes back.
    ///
    /// The landing is spring-driven per frame, so swapping the node mid-collapse simply places it
    /// at the current progress and lets the collapse carry it the rest of the way.
    public var canReplaceTopAtDetent: Bool {
        guard let transition = self.state.transition else {
            return false
        }
        return transition.coordinator.hasRested && !transition.coordinator.animatingCompletion
    }

    private func updatePeekSelection(_ isSelected: Bool, transition: ContainedViewLayoutTransition) {
        guard let below = self.state.transition?.previous.value else {
            return
        }
        let data: Any? = isSelected ? self.state.top?.value.customData : nil
        below.updateNavigationPeekHighlight(data, progress: isSelected ? 1.0 : 0.0, transition: transition)
    }

    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard let layout = self.state.layout else {
                return
            }
            if let coordinator = self.state.transition?.coordinator, coordinator.isResting {
                // Everything this branch would set up already exists — both controllers are in the
                // hierarchy, the coordinator holds their nodes. Take it over where it stands.
                coordinator.beginTakeover()
                self.gestureStartProgress = coordinator.progress
                self.peekHapticFeedback.prepareImpact(.light)
                self.peekHapticFeedback.prepareTap()
                return
            }
            guard self.state.transition == nil else {
                return
            }
            self.gestureStartProgress = 0.0
            self.isPeekPreviewLatched = false
            self.peekHapticFeedback.prepareImpact(.light)
            self.peekHapticFeedback.prepareTap()
            
            let beginGesture = self.controllers.count > 1
            
            if beginGesture {
                let topController = self.controllers[self.controllers.count - 1]
                let bottomController = self.controllers[self.controllers.count - 2]

                // Settled once, here: the detent is not a generic navigation feature, it only
                // means something when the page underneath is a list to switch between. Every
                // other back swipe in the app has to behave exactly as it did.
                self.isDetentAvailable = topController.supportsNavigationDetent && bottomController.supportsNavigationDetentColumn
                
                if !topController.attemptNavigation({ [weak self, weak topController] in
                    if let self, let topController {
                        self.requestFilterController(topController)
                    }
                }) {
                    return
                }
                
                topController.viewWillDisappear(true)
                let topNode = topController.displayNode
                var bottomControllerLayout = layout
                if bottomController.view.disableAutomaticKeyboardHandling.isEmpty {
                    if let minimizedContainer = self.minimizedContainer, (bottomControllerLayout.inputHeight ?? 0.0) > 0.0 {
                        var updatedSize = bottomControllerLayout.size
                        var updatedIntrinsicInsets = bottomControllerLayout.intrinsicInsets
                        updatedSize.height -= minimizedContainer.collapsedHeight(layout: layout)
                        updatedIntrinsicInsets.bottom = 0.0
                        bottomControllerLayout = bottomControllerLayout.withUpdatedSize(updatedSize).withUpdatedIntrinsicInsets(updatedIntrinsicInsets)
                    }
                    bottomControllerLayout = bottomControllerLayout.withUpdatedInputHeight(nil)
                }
                bottomController.containerLayoutUpdated(bottomControllerLayout, transition: .immediate)
                bottomController.viewWillAppear(true)
                let bottomNode = bottomController.displayNode
                
                let screenCornerRadius = self.minimizedContainer == nil && self.state.canBeClosed != true ? layout.deviceMetrics.screenCornerRadius : 0.0
                let navigationTransitionCoordinator = NavigationTransitionCoordinator(transition: .Pop, isInteractive: true, isFlat: self.isFlat, container: self, topNode: topNode, topNavigationBar: topController.transitionNavigationBar, bottomNode: bottomNode, bottomNavigationBar: bottomController.transitionNavigationBar, screenCornerRadius: screenCornerRadius, didUpdateProgress: { [weak self, weak bottomController] progress, transition, topFrame, bottomFrame in
                    if let strongSelf = self {
                        strongSelf.state.transition?.previous.value.updateNavigationPeekProgress(progress, transition: transition)
                        if let top = strongSelf.state.top {
                            strongSelf.syncKeyboard(leftEdge: top.value.displayNode.frame.minX, transition: transition)
                            
                            var updatedStatusBarStyle = strongSelf.statusBarStyle
                            if let bottomController = bottomController, progress >= 0.3 {
                                updatedStatusBarStyle = bottomController.statusBar.statusBarStyle
                            } else {
                                updatedStatusBarStyle = top.value.statusBar.statusBarStyle
                            }
                            if strongSelf.statusBarStyle != updatedStatusBarStyle {
                                strongSelf.statusBarStyle = updatedStatusBarStyle
                                strongSelf.statusBarStyleUpdated?(.animated(duration: 0.3, curve: .easeInOut))
                            }
                        }
                    }
                })
                bottomController.displayNode.recursivelyEnsureDisplaySynchronously(true)
                navigationTransitionCoordinator.peekPresenceUpdated = { [weak self] presence in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.state.top?.value.updateNavigationPeekPresence(presence)
                    // The page below gets it too: it is the other half of the same preview, and
                    // its own chrome has no job while it is being turned into a column to pick
                    // from.
                    strongSelf.state.transition?.previous.value.updateNavigationPeekPresence(presence)
                }
                self.state.transition = TopTransition(type: .pop, previous: Child(value: bottomController, layout: layout), coordinator: navigationTransitionCoordinator)

                // Has to come after the transition exists — this reads `state.transition` to find
                // the controller below, and the whole point is to tell that controller what is on
                // top of it.
                //
                // The selection says "this is the chat you have open", which is true for as long
                // as the chat is on screen, not only when a release would land on the detent.
                // Driving it from the prediction made it blink on every flip.
                // No fade in: the block is meant to have been there since the chat was opened
                // from this row, not to appear because a gesture started. Fading *out* on the way
                // back is a different thing and stays animated.
                self.updatePeekSelection(true, transition: .immediate)
            }
        case .changed:
            if let navigationTransitionCoordinator = self.state.transition?.coordinator, !navigationTransitionCoordinator.animatingCompletion {
                if self.isVerticalLocked {
                    // Nothing to do: the link is sampling the finger every frame, including the
                    // frames where it is not moving.
                    return
                }

                let translation = recognizer.translation(in: self.view)
                let width = self.view.frame.width
                let progress = max(0.0, min(1.0, self.gestureStartProgress + translation.x / width))
                navigationTransitionCoordinator.updateProgress(progress, transition: .immediate, completion: {})

                // Same predicate that decides the landing, run every frame so the answer is
                // previewed rather than only revealed on release.
                var detent = navigationInteractiveDetent(
                    progress: progress,
                    velocity: recognizer.velocity(in: self.view).x,
                    width: width,
                    isPeekPending: self.isPeekPending
                )
                if !self.isDetentAvailable, detent == .peek {
                    // This pair does not do detents, so the only question left is the original
                    // one: does this release finish the pop or undo it.
                    detent = progress > 0.5 ? .complete : .cancel
                }
                let isPeekPending = detent == .peek
                self.isPeekPending = isPeekPending

                // The preview latches: the prediction can only switch it on, and only leaving the
                // window switches it off.
                var latched = self.isPeekPreviewLatched
                if !NavigationInteractiveDetentMetrics.peekWindow.contains(progress) {
                    latched = false
                } else if isPeekPending {
                    latched = true
                }
                if latched != self.isPeekPreviewLatched {
                    self.isPeekPreviewLatched = latched
                    navigationTransitionCoordinator.setPeekBlurred(latched, node: self.state.top?.value.navigationPeekBackdropNode)
                    if latched {
                        self.peekHapticFeedback.impact(.light)
                    }
                }
                // The lag means "this page is behind another one". Going back to the controller on
                // top is the only direction where that becomes true again — towards the detent or
                // towards the pop the page below is the one in front, so it stays put. Without the
                // second half of this the page below runs back out to its lagging position on the
                // way to a pop and then has to come all the way back, which reads as a jump.
                //
                // Gated on having rested so a plain back swipe keeps its stock behaviour.
                navigationTransitionCoordinator.setParallaxSettled(latched || (navigationTransitionCoordinator.hasRested && detent != .cancel))

                // Once the detent is being predicted, enough vertical travel takes the gesture
                // over: the horizontal component stops mattering, the detent is held, and the
                // rest of the gesture drives the list instead.
                // Before the takeover the block cannot move yet, but it can lean — so the
                // threshold is something the finger is visibly approaching, not a trapdoor.
                self.state.transition?.previous.value.updateNavigationPeekLean(
                    latched ? translation.y * NavigationInteractiveDetentMetrics.highlightRowLeanFactor : 0.0
                )

                if latched, abs(translation.y) > NavigationInteractiveDetentMetrics.verticalLockThreshold {
                    self.isVerticalLocked = true
                    navigationTransitionCoordinator.animateRest(to: NavigationInteractiveDetentMetrics.peekProgress(width: width), velocity: 0.0)
                    self.peekHapticFeedback.impact(.medium)
                    // Handed over: the lean is now folded into the springs' targets instead of
                    // sitting on top as a separate offset.
                    self.state.transition?.previous.value.updateNavigationPeekLean(0.0)
                    self.startVerticalLockLink()
                }
            }
        case .ended, .cancelled:
            if self.isVerticalLocked {
                self.isVerticalLocked = false
                self.stopVerticalLockLink()
                // Ends the drag, and makes the column work out whether it is asking for a
                // different page. Has to happen before the question below is asked.
                self.updatePeekDrag(at: nil)

                if self.state.transition?.previous.value.navigationPeekDragRequestedSwitch == true {
                    // A page is on its way. Collapsing over one that is still assembling itself
                    // is the hitch, so wait for it to land.
                    self.dismissWhenTopLands = true
                    Queue.mainQueue().after(1.0, { [weak self] in
                        // Never leave the detent stuck open because a load never finished.
                        guard let strongSelf = self, strongSelf.dismissWhenTopLands else {
                            return
                        }
                        strongSelf.dismissWhenTopLands = false
                        strongSelf.dismissRestingTransition()
                    })
                } else {
                    // Released on the page already open. Nothing to wait for.
                    self.dismissRestingTransition()
                }
                return
            }
            if let navigationTransitionCoordinator = self.state.transition?.coordinator, !navigationTransitionCoordinator.animatingCompletion {
                let velocity = recognizer.velocity(in: self.view).x
                let width = self.view.frame.width

                var detent = navigationInteractiveDetent(
                    progress: navigationTransitionCoordinator.progress,
                    velocity: velocity,
                    width: width,
                    isPeekPending: self.isPeekPending
                )
                if !self.isDetentAvailable, detent == .peek {
                    detent = navigationTransitionCoordinator.progress > 0.5 ? .complete : .cancel
                }
                self.isPeekPending = detent == .peek

                // The outcome is the predicate's, not the latch's: a fast flick still pops.
                self.isPeekPreviewLatched = false
                navigationTransitionCoordinator.setPeekBlurred(detent == .peek, node: self.state.top?.value.navigationPeekBackdropNode)
                if detent != .peek {
                    self.updatePeekSelection(false, transition: .animated(duration: 0.2, curve: .easeInOut))
                }

                if detent == .peek {
                    navigationTransitionCoordinator.animateRest(to: NavigationInteractiveDetentMetrics.peekProgress(width: width), velocity: velocity)
                } else if detent == .complete {
                    self.state.top?.value.viewWillLeaveNavigation()
                    navigationTransitionCoordinator.animateCompletion(velocity, completion: { [weak self] in
                        guard let strongSelf = self, let _ = strongSelf.state.layout, let _ = strongSelf.state.transition, let top = strongSelf.state.top else {
                            return
                        }
                        
                        let topController = top.value
                        
                        if viewTreeContainsFirstResponder(view: top.value.view) {
                            strongSelf.ignoreInputHeight = true
                        }
                        strongSelf.keyboardViewManager?.dismissEditingWithoutAnimation(view: topController.view)
                        
                        strongSelf.state.transition = nil
                        
                        strongSelf.controllerRemoved(top.value)
                        strongSelf.ignoreInputHeight = false
                    })
                } else {
                    navigationTransitionCoordinator.animateCancel(velocity, completion: { [weak self] in
                        guard let strongSelf = self, let top = strongSelf.state.top, let transition = strongSelf.state.transition else {
                            return
                        }
                        strongSelf.state.transition = nil
                            
                        top.value.viewDidAppear(true)
                        transition.previous.value.viewDidDisappear(true)
                    })
                }
            }
        default:
            break
        }
    }
    
    public func update(layout: ContainerViewLayout, canBeClosed: Bool, controllers: [ViewController], transition: ContainedViewLayoutTransition) {
        self.state.layout = layout
        self.state.canBeClosed = canBeClosed
        
        var controllersUpdated = false
        if self.controllers.count != controllers.count {
            controllersUpdated = true
        } else {
            for i in 0 ..< controllers.count {
                if self.controllers[i] !== controllers[i] {
                    controllersUpdated = true
                    break
                }
            }
        }
        if controllersUpdated {
            let previousControllers = self.controllers
            self.controllers = controllers
            
            for i in 0 ..< controllers.count {
                if i == 0 {
                    if canBeClosed {
                        controllers[i].transitionNavigationBar?.previousItem = .close
                        controllers[i].previousItem = .close
                    } else {
                        controllers[i].transitionNavigationBar?.previousItem = nil
                        controllers[i].previousItem = nil
                    }
                } else {
                    controllers[i].transitionNavigationBar?.previousItem = .item(controllers[i - 1].navigationItem)
                    controllers[i].previousItem = .item(controllers[i - 1].navigationItem)
                }
            }
        
            if controllers.last !== self.state.top?.value {
                self.state.top?.value.statusBar.alphaUpdated = nil
                if let controller = controllers.last {
                    controller.statusBar.alphaUpdated = { [weak self, weak controller] transition in
                        guard let strongSelf = self, let controller = controller else {
                            return
                        }
                        if strongSelf.state.top?.value === controller && strongSelf.state.transition == nil {
                            strongSelf.statusBarStyleUpdated?(transition)
                        }
                    }
                }
                
                if controllers.last !== self.state.pending?.value.value {
                    self.state.pending = nil
                    if let last = controllers.last {
                        let transitionType: PendingChild.TransitionType
                        if !previousControllers.contains(where: { $0 === last }) {
                            transitionType = .push
                        } else {
                            transitionType = .pop
                        }
                        var updatedLayout = layout
                        if last.view.disableAutomaticKeyboardHandling.isEmpty {
                            updatedLayout = updatedLayout.withUpdatedInputHeight(nil)
                        }
                        let pendingChild = PendingChild(value: self.makeChild(layout: updatedLayout, value: last), transitionType: transitionType, transition: transition, update: { [weak self] pendingChild in
                            self?.pendingChildIsReady(pendingChild)
                        })
                        // The readiness gate stays. Tried bypassing it twice: a chat that is
                        // put on screen before it is ready does not show a loading placeholder,
                        // it draws nothing at all — the page below shows through the hole. There
                        // is no view to show yet, so there is nothing to trade the wait against.
                        self.state.pending = pendingChild
                    }
                }
            }
        }
        
        var statusBarTransition = transition
        
        var ignoreInputHeight = false
        if let pending = self.state.pending {
            if pending.isReady {
                self.state.pending = nil
                let previous = self.state.top
                previous?.value.isInFocus = false
                self.state.top = pending.value
                var updatedLayout = layout
                if pending.value.value.view.disableAutomaticKeyboardHandling.isEmpty {
                    updatedLayout = updatedLayout.withUpdatedInputHeight(nil)
                }
                if case .regular = layout.metrics.widthClass, pending.value.layout.inputHeight == nil {
                    ignoreInputHeight = true
                }
                self.topTransition(from: previous, to: pending.value, transitionType: pending.transitionType, layout: updatedLayout, transition: pending.transition)
                self.state.top?.value.isInFocus = self.isInFocus
                statusBarTransition = pending.transition
                if !self.isReady {
                    self.isReady = true
                    self.isReadyUpdated?()
                }
            }
        }
        
        if controllers.isEmpty && self.state.top != nil {
            let previous = self.state.top
            previous?.value.isInFocus = false
            self.state.top = nil
            self.topTransition(from: previous, to: nil, transitionType: .pop, layout: layout, transition: .immediate)
        }
        
        var updatedStatusBarStyle = self.statusBarStyle
        if let top = self.state.top {
            var updatedLayout = layout
            if let _ = self.state.transition, top.value.view.disableAutomaticKeyboardHandling.isEmpty {
                if !viewTreeContainsFirstResponder(view: top.value.view) {
                    updatedLayout = updatedLayout.withUpdatedInputHeight(nil)
                }
            }
            if ignoreInputHeight {
                updatedLayout = updatedLayout.withUpdatedInputHeight(nil)
            }
            self.applyLayout(layout: updatedLayout, to: top, isMaster: true, transition: transition)
            if let childTransition = self.state.transition, childTransition.coordinator.isInteractive {
                switch childTransition.type {
                case .push:
                    if childTransition.coordinator.progress >= 0.3 {
                        updatedStatusBarStyle = top.value.statusBar.statusBarStyle
                    } else {
                        updatedStatusBarStyle = childTransition.previous.value.statusBar.statusBarStyle
                    }
                case .pop:
                    if childTransition.coordinator.progress >= 0.3 {
                        updatedStatusBarStyle = childTransition.previous.value.statusBar.statusBarStyle
                    } else {
                        updatedStatusBarStyle = top.value.statusBar.statusBarStyle
                    }
                }
            } else {
                updatedStatusBarStyle = top.value.statusBar.statusBarStyle
            }
        } else {
            updatedStatusBarStyle = .Ignore
        }
        if self.statusBarStyle != updatedStatusBarStyle {
            self.statusBarStyle = updatedStatusBarStyle
            self.statusBarStyleUpdated?(statusBarTransition)
        }
    }
    
    public var shouldAnimateDisappearance: Bool = false
    
    private func topTransition(from fromValue: Child?, to toValue: Child?, transitionType: PendingChild.TransitionType, layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        if case .animated = transition, let fromValue = fromValue, let toValue = toValue {
            if let currentTransition = self.state.transition {
                currentTransition.coordinator.performCompletion(completion: {
                })
            }
            
            fromValue.value.viewWillLeaveNavigation()
            fromValue.value.viewWillDisappear(true)
            toValue.value.viewWillAppear(true)
            toValue.value.setIgnoreAppearanceMethodInvocations(true)
            if let layout = self.state.layout {
                toValue.value.displayNode.frame = CGRect(origin: CGPoint(), size: layout.size)
            }
            let mappedTransitionType: NavigationTransition
            let topController: ViewController
            let bottomController: ViewController
            switch transitionType {
            case .push:
                mappedTransitionType = .Push
                self.addSubnode(toValue.value.displayNode)
                topController = toValue.value
                bottomController = fromValue.value
            case .pop:
                mappedTransitionType = .Pop
                self.insertSubnode(toValue.value.displayNode, belowSubnode: fromValue.value.displayNode)
                topController = fromValue.value
                bottomController = toValue.value
            }
            toValue.value.setIgnoreAppearanceMethodInvocations(false)
            
            let screenCornerRadius = self.minimizedContainer == nil && self.state.canBeClosed != true ? layout.deviceMetrics.screenCornerRadius : 0.0
            let topTransition = TopTransition(type: transitionType, previous: fromValue, coordinator: NavigationTransitionCoordinator(transition: mappedTransitionType, isInteractive: false, isFlat: self.isFlat, container: self, topNode: topController.displayNode, topNavigationBar: topController.transitionNavigationBar, bottomNode: bottomController.displayNode, bottomNavigationBar: bottomController.transitionNavigationBar, screenCornerRadius: screenCornerRadius, didUpdateProgress: { [weak self, weak bottomController] progress, transition, topFrame, bottomFrame in
                guard let strongSelf = self else {
                    return
                }
                // The page underneath derives its own appearance from this — avatars scaled down
                // while it is covered. Scripted push and pop have to report it too, or whatever
                // the gesture last set stays stuck after an ordinary back button.
                switch transitionType {
                case .push:
                    bottomController?.updateNavigationPeekProgress(1.0 - progress, transition: transition)
                case .pop:
                    bottomController?.updateNavigationPeekProgress(progress, transition: transition)
                }
                switch transitionType {
                case .push:
                    if let _ = strongSelf.state.transition, let top = strongSelf.state.top, viewTreeContainsFirstResponder(view: top.value.view) {
                        strongSelf.syncKeyboard(leftEdge: topFrame.minX, transition: transition)
                    } else {
                        if let hasActiveInput = strongSelf.state.top?.value.hasActiveInput, hasActiveInput {
                        } else {
                            strongSelf.syncKeyboard(leftEdge: topFrame.minX - bottomFrame.width, transition: transition)
                        }
                    }
                case .pop:
                    strongSelf.syncKeyboard(leftEdge: topFrame.minX, transition: transition)
                }
            }))
            self.state.transition = topTransition
            
            topTransition.coordinator.animateCompletion(0.0, completion: { [weak self, weak topTransition] in
                guard let strongSelf = self, let topTransition = topTransition, strongSelf.state.transition === topTransition else {
                    return
                }
                
                if viewTreeContainsFirstResponder(view: topTransition.previous.value.view) {
                    strongSelf.ignoreInputHeight = true
                }
                strongSelf.keyboardViewManager?.dismissEditingWithoutAnimation(view: topTransition.previous.value.view)
                strongSelf.state.transition = nil
                
                if strongSelf.shouldAnimateDisappearance {
                    let displayNode = topTransition.previous.value.displayNode
                    displayNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak displayNode] _ in
                        displayNode?.removeFromSupernode()
                        displayNode?.layer.removeAllAnimations()
                    })
                } else {
                    topTransition.previous.value.setIgnoreAppearanceMethodInvocations(true)
                    topTransition.previous.value.displayNode.removeFromSupernode()
                    topTransition.previous.value.setIgnoreAppearanceMethodInvocations(false)
                }
                topTransition.previous.value.viewDidDisappear(true)
                if let toValue = strongSelf.state.top, let layout = strongSelf.state.layout {
                    toValue.value.displayNode.frame = CGRect(origin: CGPoint(), size: layout.size)
                    strongSelf.applyLayout(layout: layout, to: toValue, isMaster: true, transition: .immediate)
                    toValue.value.viewDidAppear(true)
                }
                
                strongSelf.ignoreInputHeight = false
            })
        } else {
            if let fromValue = fromValue {
                if viewTreeContainsFirstResponder(view: fromValue.value.view) {
                    self.ignoreInputHeight = true
                }
                
                fromValue.value.viewWillLeaveNavigation()
                fromValue.value.viewWillDisappear(false)
                
                self.keyboardViewManager?.dismissEditingWithoutAnimation(view: fromValue.value.view)
                
                fromValue.value.setIgnoreAppearanceMethodInvocations(true)
                fromValue.value.displayNode.removeFromSupernode()
                fromValue.value.setIgnoreAppearanceMethodInvocations(false)
                fromValue.value.viewDidDisappear(false)
            }
            if let toValue = toValue {
                self.applyLayout(layout: layout, to: toValue, isMaster: true, transition: .immediate)
                toValue.value.displayNode.frame = CGRect(origin: CGPoint(), size: layout.size)
                toValue.value.viewWillAppear(false)
                toValue.value.setIgnoreAppearanceMethodInvocations(true)
                self.addSubnode(toValue.value.displayNode)
                toValue.value.setIgnoreAppearanceMethodInvocations(false)
                toValue.value.displayNode.recursivelyEnsureDisplaySynchronously(true)
                toValue.value.viewDidAppear(false)

                // The swap above pulled the old node out from under a transition that is parked
                // and is meant to stay parked. Re-point it at the node that took its place; the
                // node below, the dim and the progress are all still valid.
                if let currentTransition = self.state.transition, currentTransition.coordinator.hasRested, !currentTransition.coordinator.animatingCompletion {
                    let screenCornerRadius = self.minimizedContainer == nil && self.state.canBeClosed != true ? layout.deviceMetrics.screenCornerRadius : 0.0
                    currentTransition.coordinator.replaceTopNode(toValue.value.displayNode, screenCornerRadius: screenCornerRadius)
                    currentTransition.coordinator.setPeekBlurred(self.isPeekPending || self.isVerticalLocked, node: toValue.value.navigationPeekBackdropNode)
                    self.updatePeekSelection(true, transition: .animated(duration: 0.3, curve: .easeInOut))

                    // Picking something in the exposed column is a choice, and the detent exists
                    // to let a choice be made — so making one puts it away. The swap above already
                    // happened, so the content is correct before the collapse starts.
                    //
                    // Deferred by one turn of the run loop: this runs inside the layout pass, and
                    // the rest of that pass still reads `state.transition`, which the collapse
                    // eventually clears.
                    self.columnTapDismissalToken += 1
                    // Not while the gesture is driving the list: there the chat changes on every
                    // row crossed, and collapsing on the first one would end the gesture.
                    if !self.isVerticalLocked {
                        self.dismissWhenTopLands = false
                        Queue.mainQueue().justDispatch { [weak self] in
                            self?.dismissRestingTransition()
                        }
                    }
                }
            }
            self.ignoreInputHeight = false
        }
    }
    
    private func makeChild(layout: ContainerViewLayout, value: ViewController) -> Child {
        var updatedLayout = layout
        if value.view.disableAutomaticKeyboardHandling.isEmpty {
            updatedLayout = updatedLayout.withUpdatedInputHeight(nil)
        }
        value.containerLayoutUpdated(updatedLayout, transition: .immediate)
        return Child(value: value, layout: updatedLayout)
    }
    
    private func applyLayout(layout: ContainerViewLayout, to child: Child, isMaster: Bool, transition: ContainedViewLayoutTransition) {
        var childFrame = CGRect(origin: CGPoint(), size: layout.size)
        
        var updatedLayout = layout
        
        var shouldSyncKeyboard = false
        if let transition = self.state.transition {
            childFrame.origin.x = child.value.displayNode.frame.origin.x
            switch transition.type {
            case .pop:
                if transition.previous.value === child.value {
                    shouldSyncKeyboard = true
                }
            case .push:
                break
            }
            if updatedLayout.inputHeight != nil {
                if !self.canHaveKeyboardFocus && child.value.view.disableAutomaticKeyboardHandling.isEmpty {
                    updatedLayout = updatedLayout.withUpdatedInputHeight(nil)
                }
            }
        } else {
            if isMaster {
                shouldSyncKeyboard = true
            }
            
            if updatedLayout.inputHeight != nil && child.value.view.disableAutomaticKeyboardHandling.isEmpty {
                if !self.canHaveKeyboardFocus || self.ignoreInputHeight {
                    updatedLayout = updatedLayout.withUpdatedInputHeight(nil)
                }
            }
        }
        if child.value.displayNode.frame != childFrame {
            transition.updateFrame(node: child.value.displayNode, frame: childFrame)
        }
        if shouldSyncKeyboard && isMaster {
            self.syncKeyboard(leftEdge: childFrame.minX, transition: transition)
        }
        if child.layout != updatedLayout {
            child.layout = updatedLayout
            child.value.containerLayoutUpdated(updatedLayout, transition: transition)
        }
    }
    
    public func updateAdditionalKeyboardLeftEdgeOffset(_ offset: CGFloat, transition: ContainedViewLayoutTransition) {
        self.additionalKeyboardLeftEdgeOffset = offset
        self.syncKeyboard(leftEdge: self.currentKeyboardLeftEdge, transition: transition)
    }
    
    private func syncKeyboard(leftEdge: CGFloat, transition: ContainedViewLayoutTransition) {
        self.currentKeyboardLeftEdge = leftEdge
        self.keyboardViewManager?.update(leftEdge: self.additionalKeyboardLeftEdgeOffset + leftEdge, transition: transition)
    }
    
    private func pendingChildIsReady(_ child: PendingChild) {

        if let pending = self.state.pending, pending === child {
            pending.isReady = true
            self.performUpdate(transition: .immediate)
        }
    }
    
    private func performUpdate(transition: ContainedViewLayoutTransition) {
        if let layout = self.state.layout, let canBeClosed = self.state.canBeClosed {
            self.update(layout: layout, canBeClosed: canBeClosed, controllers: self.controllers, transition: transition)
        }
    }
    
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        // Swallowing touches is right while a transition is *moving* — a tap would land on a
        // controller that is halfway somewhere. A transition parked at a detent is not moving and
        // both controllers are where they will stay, so it has to be transparent to hit testing.
        if let transition = self.state.transition, !transition.coordinator.isResting {
            return self.view
        }
        return super.hitTest(point, with: event)
    }
    
    func combinedSupportedOrientations(currentOrientationToLock: UIInterfaceOrientationMask) -> ViewControllerSupportedOrientations {
        var supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .allButUpsideDown)
        if let controller = self.controllers.last {
            if controller.lockOrientation {
                if let lockedOrientation = controller.lockedOrientation {
                    supportedOrientations = supportedOrientations.intersection(ViewControllerSupportedOrientations(regularSize: lockedOrientation, compactSize: lockedOrientation))
                } else {
                    supportedOrientations = supportedOrientations.intersection(ViewControllerSupportedOrientations(regularSize: currentOrientationToLock, compactSize: currentOrientationToLock))
                }
            } else {
                supportedOrientations = supportedOrientations.intersection(controller.supportedOrientations)
            }
        }
        if let transition = self.state.transition {
            let controller = transition.previous.value
            if controller.lockOrientation {
                if let lockedOrientation = controller.lockedOrientation {
                    supportedOrientations = supportedOrientations.intersection(ViewControllerSupportedOrientations(regularSize: lockedOrientation, compactSize: lockedOrientation))
                } else {
                    supportedOrientations = supportedOrientations.intersection(ViewControllerSupportedOrientations(regularSize: currentOrientationToLock, compactSize: currentOrientationToLock))
                }
            } else {
                supportedOrientations = supportedOrientations.intersection(controller.supportedOrientations)
            }
        }
        return supportedOrientations
    }
}
