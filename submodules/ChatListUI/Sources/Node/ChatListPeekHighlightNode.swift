import Foundation
import UIKit
import AsyncDisplayKit
import Display

/// The selection block drawn while the navigation transition is parked at a detent.
///
/// Deliberately *not* the per-row highlight that `ChatListItemNode` already has. That one lives
/// inside a row, so it cannot sit between two rows, cannot be split, and cannot outlive the row
/// being recycled — and all three are things the vertical gesture needs.
///
/// Split at `columnWidth`, which is the edge of the column the detent exposes: the leading piece
/// is the part the user can see and is the only one that moves, while the trailing piece sits
/// under the chat and only exists so the block reads as one bar when nothing is happening.
final class ChatListPeekHighlightNode: ASDisplayNode {
    /// Width of the column the detent exposes.
    ///
    /// Matches the row's own geometry exactly: `avatarLeftEdgeInset * 2 + avatarDiameter`, i.e.
    /// 16 + 60 + 16, so the avatar sits centred in the column with equal padding on both sides.
    /// Derived from a size rather than stated as a fraction, because that constraint is the same
    /// on every device while a fraction drifts with the screen width.
    static let columnWidth: CGFloat = 92.0

    /// Corner radius the leading piece takes once the gesture has been taken over vertically.
    static let lockedCornerRadius: CGFloat = 20.0

    private let leadingNode: ASDisplayNode
    private let trailingNode: ASDisplayNode
    override init() {
        self.leadingNode = ASDisplayNode()
        self.trailingNode = ASDisplayNode()
        super.init()

        self.isUserInteractionEnabled = false
        self.leadingNode.layer.cornerCurve = .continuous
        self.trailingNode.layer.cornerCurve = .continuous
        self.addSubnode(self.trailingNode)
        self.addSubnode(self.leadingNode)
    }

    /// The colour to lay *over* a row so that it ends up looking highlighted.
    ///
    /// A row is opaque — its own background node is drawn first, and the highlight the row draws
    /// for itself goes above that but below the avatar and the text. From outside the row there is
    /// no such middle layer: anything added to the list is either entirely behind the row (and so
    /// invisible) or entirely in front of it (and so covering the content).
    ///
    /// So instead of painting the highlight colour, paint the *difference* between the highlight
    /// and the row background as a translucent black or white. Over the background it reproduces
    /// the highlight colour exactly; over the avatar and the text it is a slight shift of the same
    /// size, which is what a highlight looks like anyway.
    static func overlayColor(highlighted: UIColor, background: UIColor) -> UIColor {
        var hr: CGFloat = 0.0, hg: CGFloat = 0.0, hb: CGFloat = 0.0, ha: CGFloat = 0.0
        var br: CGFloat = 0.0, bg: CGFloat = 0.0, bb: CGFloat = 0.0, ba: CGFloat = 0.0
        guard highlighted.getRed(&hr, green: &hg, blue: &hb, alpha: &ha),
              background.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else {
            return highlighted
        }
        let highlightedLuma = (hr + hg + hb) / 3.0
        let backgroundLuma = (br + bg + bb) / 3.0

        if highlightedLuma <= backgroundLuma {
            // Light theme: the highlight is darker than the row, so darken it.
            let alpha = backgroundLuma > 0.0 ? 1.0 - highlightedLuma / backgroundLuma : 0.0
            return UIColor(white: 0.0, alpha: max(0.0, min(1.0, alpha)))
        } else {
            // Dark theme: the highlight is lighter than the row, so lighten it.
            let alpha = backgroundLuma < 1.0 ? (highlightedLuma - backgroundLuma) / (1.0 - backgroundLuma) : 0.0
            return UIColor(white: 1.0, alpha: max(0.0, min(1.0, alpha)))
        }
    }

    /// - parameter rowFrame: where the selected row currently is, in this node's coordinates.
    ///   `nil` hides the block.
    /// - parameter leadingFrame: where the leading piece should actually be drawn. Defaults to the
    ///   part of `rowFrame` inside the column; the vertical gesture overrides it.
    /// - parameter presence: 0 hidden, 1 fully drawn.
    func update(
        rowFrame: CGRect?,
        leadingFrame: CGRect?,
        columnWidth: CGFloat,
        presence: CGFloat,
        cornerRadius: CGFloat,
        trailingAlpha: CGFloat,
        color: UIColor,
        transition: ContainedViewLayoutTransition
    ) {
        guard let rowFrame, presence > 0.0 else {
            transition.updateAlpha(node: self, alpha: 0.0)
            return
        }

        let resolvedLeading = leadingFrame ?? CGRect(
            origin: rowFrame.origin,
            size: CGSize(width: min(columnWidth, rowFrame.width), height: rowFrame.height)
        )
        let trailing = CGRect(
            x: rowFrame.minX + columnWidth,
            y: rowFrame.minY,
            width: max(0.0, rowFrame.width - columnWidth),
            height: rowFrame.height
        )

        self.leadingNode.backgroundColor = color
        self.trailingNode.backgroundColor = color

        transition.updateFrame(node: self.leadingNode, frame: resolvedLeading)
        transition.updateFrame(node: self.trailingNode, frame: trailing)
        transition.updateCornerRadius(node: self.leadingNode, cornerRadius: cornerRadius)
        // The trailing piece rounds off and fades at the same time as the leading one pulls in:
        // one block coming apart, not two things happening to a pair of rectangles.
        transition.updateCornerRadius(node: self.trailingNode, cornerRadius: cornerRadius)
        transition.updateAlpha(node: self.trailingNode, alpha: trailingAlpha)
        transition.updateAlpha(node: self, alpha: presence)

    }
}
