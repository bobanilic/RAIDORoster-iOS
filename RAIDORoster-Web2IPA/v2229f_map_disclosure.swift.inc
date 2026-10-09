// V2.29.5 blended map disclosure
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

// Disclosure owns its direction before scrolling begins; it never waits for
// the page to bounce and never snaps contentOffset after a simultaneous scroll.
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
        private var originalBounces = true
        private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        init(_ parent: TodayMapDisclosureObserver) { self.parent = parent }
        func attach(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor {
                if let found = current as? UIScrollView {
                    guard scroll !== found else { return }
                    detach()
                    scroll = found
                    originalBounces = found.bounces
                    found.bounces = false
                    drag.name = "raido.map.disclosure"
                    drag.delegate = self
                    drag.maximumNumberOfTouches = 1
                    drag.cancelsTouchesInView = true
                    found.addGestureRecognizer(drag)
                    return
                }
                ancestor = current.superview
            }
        }
        func detach() {
            scroll?.removeGestureRecognizer(drag)
            scroll?.bounces = originalBounces
            scroll = nil
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let scroll else { return false }
            let velocity = drag.velocity(in: scroll)
            guard abs(velocity.y) > abs(velocity.x) * 1.4 else { return false }
            // Down expands at the top. Up collapses an open header. Ordinary
            // upward agenda scrolling and downward map pans remain available.
            if parent.expanded { return velocity.y < 0 }
            return velocity.y > 0 && scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
        }
        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { beganExpanded = parent.expanded }
            guard recognizer.state == .ended, let scroll else { return }
            let delta = recognizer.translation(in: scroll)
            guard let destination = MapExpansionGesture.destination(expanded: beganExpanded,
                horizontal: delta.x, vertical: delta.y), destination != parent.expanded else { return }
            // Let the map's simultaneous pan finish before reset-to-overview.
            // Otherwise its final sample can overwrite the collapse reset.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.expanded != destination else { return }
                self.parent.onToggle()
            }
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let scroll else { return false }
            // The map can pan independently, but the page must stay still.
            return other !== scroll.panGestureRecognizer
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other === scroll?.panGestureRecognizer
        }
    }
}
