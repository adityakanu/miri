import AppKit
import Foundation
import QuartzCore

public enum StatusOverlayState: Equatable, Sendable {
    case hidden
    case listening(target: String)
    case transcribing(target: String)
    case sending(target: String)
    case waiting(target: String)
    case delivered(target: String)
    case queued(target: String)
    case speaking(target: String)
    case needsInput(label: String)
    case error(message: String)
    case cancelled
}

public struct StatusOverlayPresentation: Equatable, Sendable {
    public let label: String
    public let title: String
    public let detail: String
    public let systemImage: String
    public let accessibilityLabel: String
    public let tint: StatusOverlayTint
    public let animates: Bool
    public let activity: StatusOverlayActivity

    public init(state: StatusOverlayState, reduceMotion: Bool) {
        switch state {
        case .hidden:
            title = ""; detail = ""; systemImage = ""; accessibilityLabel = "Miri hidden"; tint = .neutral; animates = false; activity = .none
        case .listening(let target):
            title = "Listening"; detail = target; systemImage = "mic.fill"; accessibilityLabel = "Listening for \(target)"; tint = .listening; animates = !reduceMotion; activity = .waveform
        case .transcribing(let target):
            title = "Transcribing"; detail = target; systemImage = "waveform"; accessibilityLabel = "Transcribing for \(target)"; tint = .neutral; animates = !reduceMotion; activity = .progress
        case .sending(let target):
            title = "Sending"; detail = target; systemImage = "paperplane.fill"; accessibilityLabel = "Sending to \(target)"; tint = .neutral; animates = !reduceMotion; activity = .progress
        case .waiting(let target):
            title = "Thinking"; detail = target; systemImage = "sparkles"; accessibilityLabel = "Waiting for \(target)"; tint = .speaking; animates = !reduceMotion; activity = .progress
        case .delivered(let target):
            title = "Delivered"; detail = target; systemImage = "checkmark"; accessibilityLabel = "Delivered to \(target)"; tint = .success; animates = false; activity = .none
        case .queued(let target):
            title = "Queued"; detail = target; systemImage = "clock.fill"; accessibilityLabel = "Queued for \(target)"; tint = .warning; animates = false; activity = .none
        case .speaking(let target):
            title = "Speaking"; detail = target; systemImage = "speaker.wave.2.fill"; accessibilityLabel = "\(target) is speaking"; tint = .speaking; animates = !reduceMotion; activity = .waveform
        case .needsInput(let value):
            title = "Needs input"; detail = value; systemImage = "questionmark.bubble.fill"; accessibilityLabel = "Needs input: \(value)"; tint = .warning; animates = !reduceMotion; activity = .progress
        case .error(let value):
            title = "Something went wrong"; detail = value; systemImage = "exclamationmark"; accessibilityLabel = "Miri error: \(value)"; tint = .error; animates = false; activity = .none
        case .cancelled:
            title = "Cancelled"; detail = ""; systemImage = "xmark"; accessibilityLabel = "Recording cancelled"; tint = .neutral; animates = false; activity = .none
        }
        label = title
    }
}

public enum StatusOverlayActivity: Equatable, Sendable { case none, waveform, progress }

public enum StatusOverlayTint: Equatable, Sendable {
    case neutral, listening, speaking, success, warning, error
}

public struct StatusOverlayGeometry: Equatable, Sendable {
    public static let defaultSize = CGSize(width: 286, height: 60)

    public static func size(for presentation: StatusOverlayPresentation) -> CGSize {
        presentation.tint == .error ? CGSize(width: 360, height: 64) : defaultSize
    }

    /// Computes a notch-adjacent origin when auxiliary menu-bar regions are available,
    /// otherwise a safe-area-aware top-center fallback.
    public static func frame(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect? = nil,
        auxiliaryTopRight: CGRect? = nil,
        size: CGSize = defaultSize,
        margin: CGFloat = 8
    ) -> CGRect {
        let centerX: CGFloat
        let topEdge: CGFloat
        if let left = auxiliaryTopLeft, let right = auxiliaryTopRight {
            centerX = (left.maxX + right.minX) / 2
            topEdge = min(left.minY, right.minY)
        } else {
            centerX = screenFrame.midX
            topEdge = screenFrame.maxY - safeAreaTop
        }
        var x = centerX - size.width / 2
        x = max(screenFrame.minX + margin, min(x, screenFrame.maxX - size.width - margin))
        let y = max(screenFrame.minY + margin, topEdge - size.height - margin)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

private final class NonActivatingStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class StatusOverlayController {
    public private(set) var state: StatusOverlayState = .hidden

    private let panel: NSPanel
    private let pillView: StatusPillView
    private var displayObserver: AccessibilityDisplayObserver?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var pinnedDisplayID: CGDirectDisplayID?

    public init(pinnedDisplayID: CGDirectDisplayID? = nil) {
        self.pinnedDisplayID = pinnedDisplayID
        pillView = StatusPillView(frame: CGRect(origin: .zero, size: StatusOverlayGeometry.defaultSize))
        panel = NonActivatingStatusPanel(
            contentRect: pillView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = pillView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        displayObserver = AccessibilityDisplayObserver { [weak self] reduceMotion in
            guard let self else { return }
            self.reduceMotion = reduceMotion
            self.pillView.update(StatusOverlayPresentation(state: self.state, reduceMotion: reduceMotion))
        }
    }

    public func setPinnedDisplay(_ displayID: CGDirectDisplayID?) {
        pinnedDisplayID = displayID
        if state != .hidden { positionPanel() }
    }

    public func show(_ newState: StatusOverlayState) {
        let wasHidden = state == .hidden
        state = newState
        guard newState != .hidden else { hide() ; return }
        let presentation = StatusOverlayPresentation(state: newState, reduceMotion: reduceMotion)
        positionPanel(size: StatusOverlayGeometry.size(for: presentation), animated: !wasHidden && !reduceMotion)
        pillView.update(presentation, transition: !wasHidden && !reduceMotion)
        if wasHidden && !reduceMotion {
            panel.alphaValue = 0
            pillView.layer?.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        } else { panel.alphaValue = 1 }
        panel.orderFrontRegardless()
        if wasHidden && !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.24)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
            pillView.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    public func hide() {
        state = .hidden
        pillView.update(StatusOverlayPresentation(state: .hidden, reduceMotion: reduceMotion))
        if reduceMotion {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 0
            } completionHandler: { [weak panel = self.panel] in
                Task { @MainActor in panel?.orderOut(nil) }
            }
        }
    }

    private func positionPanel(size: CGSize = StatusOverlayGeometry.defaultSize, animated: Bool = false) {
        guard let screen = selectedScreen() else { return }
        let target = StatusOverlayGeometry.frame(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            size: size
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(target, display: true)
            }
        } else { panel.setFrame(target, display: true) }
    }

    private func selectedScreen() -> NSScreen? {
        if let pinnedDisplayID,
           let match = NSScreen.screens.first(where: { screen in
               (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == pinnedDisplayID
           }) { return match }
        if let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen { return screen }
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }
}

@MainActor
private final class StatusPillView: NSView {
    private let iconBackdrop = NSView()
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let activityView = StatusActivityView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 0.97).cgColor
        layer?.cornerRadius = 19
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor

        iconBackdrop.translatesAutoresizingMaskIntoConstraints = false
        iconBackdrop.wantsLayer = true
        iconBackdrop.layer?.cornerRadius = 14
        iconBackdrop.layer?.cornerCurve = .continuous
        iconBackdrop.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .white
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 11, weight: .medium)
        detailField.textColor = NSColor.white.withAlphaComponent(0.55)
        detailField.lineBreakMode = .byTruncatingTail
        activityView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBackdrop); iconBackdrop.addSubview(imageView)
        addSubview(titleField); addSubview(detailField); addSubview(activityView)
        NSLayoutConstraint.activate([
            iconBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconBackdrop.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBackdrop.widthAnchor.constraint(equalToConstant: 38), iconBackdrop.heightAnchor.constraint(equalToConstant: 38),
            imageView.centerXAnchor.constraint(equalTo: iconBackdrop.centerXAnchor), imageView.centerYAnchor.constraint(equalTo: iconBackdrop.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20), imageView.heightAnchor.constraint(equalToConstant: 20),
            titleField.leadingAnchor.constraint(equalTo: iconBackdrop.trailingAnchor, constant: 11),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: activityView.leadingAnchor, constant: -10),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: activityView.leadingAnchor, constant: -10),
            activityView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            activityView.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityView.widthAnchor.constraint(equalToConstant: 28), activityView.heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ presentation: StatusOverlayPresentation, transition: Bool = false) {
        if transition {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "miri.contentTransition")
        }
        titleField.stringValue = presentation.title
        detailField.stringValue = presentation.detail
        imageView.image = NSImage(systemSymbolName: presentation.systemImage, accessibilityDescription: nil)
        let color = color(for: presentation.tint)
        imageView.contentTintColor = color
        iconBackdrop.layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityElement(presentation.label.isEmpty == false)
        activityView.update(style: presentation.activity, color: color, animated: presentation.animates)
        if transition {
            imageView.wantsLayer = true
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.86, 1.08, 1.0]; scale.keyTimes = [0, 0.62, 1]; scale.duration = 0.28
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageView.layer?.add(scale, forKey: "miri.iconTransition")
        }
    }

    private func color(for tint: StatusOverlayTint) -> NSColor {
        switch tint {
        case .neutral: .secondaryLabelColor
        case .listening: .systemBlue
        case .speaking: .systemPurple
        case .success: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        }
    }
}

@MainActor
private final class StatusActivityView: NSView {
    private let bars = (0..<3).map { _ in CALayer() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true
        for (index, bar) in bars.enumerated() {
            bar.cornerRadius = 1.5
            bar.frame = CGRect(x: CGFloat(index) * 7 + 4, y: 6, width: 3, height: 10)
            layer?.addSublayer(bar)
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(style: StatusOverlayActivity, color: NSColor, animated: Bool) {
        layer?.removeAllAnimations()
        for bar in bars { bar.removeAllAnimations(); bar.backgroundColor = color.cgColor; bar.opacity = 0 }
        guard style != .none else { isHidden = true; return }
        isHidden = false
        for (index, bar) in bars.enumerated() {
            bar.opacity = style == .progress ? Float(0.35 + Double(index) * 0.2) : 0.9
            guard animated else { continue }
            switch style {
            case .waveform:
                let animation = CABasicAnimation(keyPath: "transform.scale.y")
                animation.fromValue = 0.35; animation.toValue = index == 1 ? 1.45 : 1.05
                animation.duration = 0.38 + Double(index) * 0.07
                animation.autoreverses = true; animation.repeatCount = .infinity
                animation.beginTime = CACurrentMediaTime() + Double(index) * 0.08
                bar.add(animation, forKey: "miri.wave.\(index)")
            case .progress:
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 0.2; animation.toValue = 1
                animation.duration = 0.7; animation.autoreverses = true; animation.repeatCount = .infinity
                animation.beginTime = CACurrentMediaTime() + Double(index) * 0.16
                bar.add(animation, forKey: "miri.progress.\(index)")
            case .none: break
            }
        }
    }
}
