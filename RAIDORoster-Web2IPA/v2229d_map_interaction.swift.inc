// V2.29.3 offline map interaction
// UIKit arbitrates the map recognizers against an enclosing UIScrollView.
// Pan and pinch may cooperate with each other, never with page scrolling.
private struct OfflineMapInteractionSurface: UIViewRepresentable {
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    let interactive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        drag.delegate = context.coordinator
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(drag)
        view.addGestureRecognizer(pinch)
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "offline-map-interaction"
        view.accessibilityLabel = "Offline route map"
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.isUserInteractionEnabled = interactive
        #if DEBUG
        view.accessibilityValue = String(format: "zoom=%.3f;panX=%.1f;panY=%.1f", Double(zoom), Double(pan.width), Double(pan.height))
        #else
        view.accessibilityValue = "Zoom \(Int((zoom * 100).rounded())) percent"
        #endif
        view.accessibilityHint = "Drag to pan. Pinch to zoom. Use the handle below to collapse."
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: OfflineMapInteractionSurface
        private var panOrigin = CGSize.zero
        private var zoomOrigin: CGFloat = 1
        init(_ parent: OfflineMapInteractionSurface) { self.parent = parent }

        @objc func drag(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { panOrigin = parent.pan }
            guard recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended else { return }
            let delta = recognizer.translation(in: recognizer.view)
            parent.pan = CGSize(width: panOrigin.width + delta.x, height: panOrigin.height + delta.y)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { zoomOrigin = parent.zoom }
            guard recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended else { return }
            parent.zoom = min(7, max(1, zoomOrigin * recognizer.scale))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer.view === other.view &&
                ((gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer) ||
                 (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Lazy failure priority applies only to our actual enclosing page,
            // and disappears when this surface is removed or noninteractive.
            guard parent.interactive, let scroll = other.view as? UIScrollView,
                  other === scroll.panGestureRecognizer, let view = gestureRecognizer.view else { return false }
            return view.isDescendant(of: scroll)
        }
    }
}
