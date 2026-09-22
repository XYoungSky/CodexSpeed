import AppKit
import SwiftUI

/// Marks controls that must receive clicks instead of starting a window drag.
/// All other content is draggable. The marker itself never intercepts events.
struct WindowControlArea: NSViewRepresentable {
    final class ControlView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> ControlView { ControlView() }
    func updateNSView(_ nsView: ControlView, context: Context) {}

    static func contains(_ point: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden else { return false }
        if let region = view as? ControlView,
           region.bounds.insetBy(dx:-4,dy:-4).contains(region.convert(point, from:nil)) { return true }
        return view.subviews.contains { contains(point, in:$0) }
    }
}
