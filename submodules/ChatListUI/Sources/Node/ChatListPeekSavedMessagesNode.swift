import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import AccountContext
import TelegramPresentationData
import GlassBackgroundComponent

/// The Saved Messages shortcut the exposed column offers while a peek is held.
///
/// Lives in `ChatListNavigationBar.peekAccessoryContainer` — the strip between the title bar and
/// the folder tabs, which those two vacate when the detent fades them out. A sibling of the bar's
/// own contents rather than a layer over them, so the two can trade places without either writing
/// over the other's alpha, and so this sits above the progressive blur instead of under it.
///
/// Built the way the tab bar's search button is built (`NavigationSearchView`): a glass pill with a
/// tinted template icon in it. Same kind of thing — a control sitting over content, not a row that
/// is part of it.
final class ChatListPeekSavedMessagesNode: ASDisplayNode {
    /// The row's own metrics, from `ChatListItem`: a 60pt circle inset 16pt from the leading edge.
    /// That is what centres it in the 92pt column — the arithmetic
    /// `ChatListPeekHighlightNode.columnWidth` is built from — so it lines up with the avatars.
    static let diameter: CGFloat = 60.0
    static let leftInset: CGFloat = 16.0
    /// Nudge from the top of the strip. Zero puts this pill's top-left on the same point as the
    /// leading navigation buttons' — the strip starts at the header's top edge and those buttons
    /// sit at y = 0 of the header, so the alignment holds without a measurement.
    static let verticalOffset: CGFloat = 0.0

    private let button: HighlightTrackingButton
    private let backgroundView: GlassBackgroundView
    private let iconView: UIImageView

    var pressed: (() -> Void)?

    override init() {
        self.button = HighlightTrackingButton()
        self.backgroundView = GlassBackgroundView()
        self.backgroundView.contentView.clipsToBounds = true
        self.backgroundView.isUserInteractionEnabled = false
        self.iconView = UIImageView()

        super.init()

        self.button.addSubview(self.backgroundView)
        self.backgroundView.contentView.addSubview(self.iconView)
        self.view.addSubview(self.button)

        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        // The press feedback is ours rather than the glass's. `UIGlassEffect.isInteractive` draws
        // its own highlight, but only for touches that reach the effect view — and the button has
        // to be the touch target for the tap itself, so it gets them first. `GlassBarButtonComponent`
        // springs the same way for its non-glass states; this is that, at a size where a shrink
        // reads better than a grow.
        self.button.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            let scale: CGFloat = highlighted ? 0.88 : 1.0
            let current = (self.button.layer.presentation()?.value(forKeyPath: "transform.scale.y") as? NSNumber)?.doubleValue ?? 1.0
            self.button.layer.animateSpring(
                from: current as NSNumber,
                to: scale as NSNumber,
                keyPath: "transform.scale",
                duration: highlighted ? 0.4 : 0.5,
                removeOnCompletion: false
            )
        }
    }

    @objc private func buttonPressed() {
        self.pressed?()
    }

    /// `size` is the whole strip; the pill is a circle of `diameter` centred in it.
    func update(context: AccountContext, theme: PresentationTheme, size: CGSize, transition: ContainedViewLayoutTransition) {
        let pillFrame = CGRect(
            x: ChatListPeekSavedMessagesNode.leftInset,
            y: ChatListPeekSavedMessagesNode.verticalOffset,
            width: ChatListPeekSavedMessagesNode.diameter,
            height: ChatListPeekSavedMessagesNode.diameter
        )
        // The button carries the press scale, so it is the pill and nothing larger — scaling a
        // strip-sized view would move the icon off its own centre.
        self.button.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        transition.updateFrame(view: self.button, frame: pillFrame)
        transition.updateFrame(view: self.backgroundView, frame: CGRect(origin: CGPoint(), size: pillFrame.size))
        self.backgroundView.update(
            size: pillFrame.size,
            cornerRadius: pillFrame.height * 0.5,
            isDark: theme.overallDarkAppearance,
            tintColor: .init(kind: .panel),
            isInteractive: true,
            transition: ComponentTransition(transition)
        )

        if self.iconView.image == nil {
            self.iconView.image = UIImage(bundleImageName: "Avatar/SavedMessagesIcon")?.withRenderingMode(.alwaysTemplate)
        }
        self.iconView.tintColor = theme.chat.inputPanel.panelControlColor

        if let image = self.iconView.image {
            self.iconView.frame = CGRect(
                origin: CGPoint(
                    x: floor((pillFrame.width - image.size.width) / 2.0),
                    y: floor((pillFrame.height - image.size.height) / 2.0)
                ),
                size: image.size
            )
        }
    }
}
