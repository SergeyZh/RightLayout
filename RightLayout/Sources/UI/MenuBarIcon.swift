import AppKit
import SwiftUI

/// The menu bar icon: a keyboard, crossed out while secure input hides typing from us.
public struct MenuBarIcon: View {
    @ObservedObject private var secureInput = SecureInputMonitor.shared

    public init() {}

    public var body: some View {
        if secureInput.state.isActive {
            Image(nsImage: Self.crossedOutKeyboard)
        } else {
            Image(systemName: "keyboard")
        }
    }

    @MainActor
    private static let crossedOutKeyboard: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let keyboard = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: nil) ?? NSImage()
        }
        let image = NSImage(size: keyboard.size, flipped: false) { rect in
            keyboard.draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let start = CGPoint(x: rect.minX + 1.5, y: rect.maxY - 0.5)
            let end = CGPoint(x: rect.maxX - 1.5, y: rect.minY + 0.5)
            context.setLineCap(.round)
            // Cut a gap around the slash, as SF Symbols' ".slash" variants do.
            context.setBlendMode(.clear)
            context.setLineWidth(4)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.setBlendMode(.normal)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.6)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            return true
        }
        // Drawn like the system's menu bar icons: dark or light to match the menu bar.
        image.isTemplate = true
        image.accessibilityDescription = UIStrings.text("Secure input is on")
        return image
    }()
}

/// The status item behind the SwiftUI `MenuBarExtra`, which has no tooltip of its own.
@MainActor
public enum MenuBarStatusItem {
    public static func setToolTip(_ toolTip: String?) {
        // Let SwiftUI update the icon first, and wait for the status item at launch.
        Task { @MainActor in
            for _ in 0..<5 {
                if let button = statusButton() {
                    button.toolTip = toolTip
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = findStatusButton(in: window.contentView?.superview ?? window.contentView) {
                return button
            }
        }
        return nil
    }

    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let button = findStatusButton(in: subview) {
                return button
            }
        }
        return nil
    }
}
