// V2.29.4 frosted map disclosure
private struct MapHeaderTapControl: UIViewRepresentable {
    let expanded: Bool
    let onToggle: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        button.accessibilityIdentifier = "today-map-handle"
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.accessibilityLabel = expanded ? "Collapse flight map" : "Expand flight map"
        button.accessibilityValue = expanded ? "Expanded" : "Collapsed"
    }
    final class Coordinator: NSObject {
        var parent: MapHeaderTapControl
        init(_ parent: MapHeaderTapControl) { self.parent = parent }
        @objc func tap() { parent.onToggle() }
    }
}

// A passive one-finger recognizer observes the whole enclosing Today page.
// Short page scrolls, map pans and two-finger pinches keep their own behavior.
private struct TodayMapDisclosureObserver: UIViewRepresentable {
    let expanded: Bool
    let onToggle: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.connect = { [weak coordinator = context.coordinator] view in coordinator?.attach(from: view) }
        return view
    }
    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(from: view)
    }
    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
        view.connect = nil
    }
    final class AttachmentView: UIView {
        var connect: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); connect?(self) }
        override func layoutSubviews() { super.layoutSubviews(); connect?(self) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TodayMapDisclosureObserver
        private weak var scroll: UIScrollView?
        private var beganExpanded = false
        private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        init(_ parent: TodayMapDisclosureObserver) { self.parent = parent }
        func attach(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor {
                if let found = current as? UIScrollView {
                    guard scroll !== found else { return }
                    detach()
                    scroll = found
                    drag.delegate = self
                    drag.maximumNumberOfTouches = 1
                    drag.cancelsTouchesInView = false
                    found.addGestureRecognizer(drag)
                    return
                }
                ancestor = current.superview
            }
        }
        func detach() { scroll?.removeGestureRecognizer(drag); scroll = nil }
        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { beganExpanded = parent.expanded }
            guard recognizer.state == .ended, let scroll else { return }
            let delta = recognizer.translation(in: scroll)
            guard let destination = MapExpansionGesture.destination(expanded: beganExpanded,
                horizontal: delta.x, vertical: delta.y), destination != parent.expanded else { return }
            // Stop the page's residual momentum and bring the revealed map into
            // view. Map-only pans already take priority over the page recognizer.
            let enabled = scroll.panGestureRecognizer.isEnabled
            scroll.panGestureRecognizer.isEnabled = false
            scroll.panGestureRecognizer.isEnabled = enabled
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            parent.onToggle()
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
