import DarkroomCore
import SwiftUI

/// The crop box on the photo, drawn while the crop tool is open (the canvas then shows the frame before the crop).
/// Drag a corner or an edge to move it, drag inside to move the whole box. It writes the same four crop values as the
/// tool's Edges sliders, so the two stay in step and a drag is one History step.
struct CropOverlay: View {
    @Bindable var model: DarkroomModel
    /// The photo's rectangle in the canvas, in points.
    let photo: CGRect

    private enum Grab { case corner(Bool, Bool), edge(horizontal: Bool, first: Bool), inside }
    @State private var start: CropRect?
    @State private var grab: Grab?

    private static let reach: CGFloat = 14
    private static let smallest = 0.05

    var body: some View {
        let r = model.cropRect
        let box = CGRect(x: photo.minX + r.left * photo.width, y: photo.minY + r.top * photo.height,
                         width: (r.right - r.left) * photo.width, height: (r.bottom - r.top) * photo.height)
        ZStack(alignment: .topLeading) {
            // the cut-away dimmed, the kept part clear
            Path { p in p.addRect(photo); p.addRect(box) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Path { p in
                for i in 1...2 {
                    let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                    p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                .allowsHitTesting(false)
            ForEach(Array(handles(box).enumerated()), id: \.offset) { _, h in
                Rectangle().fill(Color.white).frame(width: 9, height: 9).position(h).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    if start == nil { start = model.cropRect; grab = hit(v.startLocation, box: box) }
                    guard let s = start, let g = grab, photo.width > 0, photo.height > 0 else { return }
                    let dx = Double(v.translation.width / photo.width), dy = Double(v.translation.height / photo.height)
                    model.setCrop(moved(s, g, dx, dy))
                }
                .onEnded { _ in start = nil; grab = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("Crop box")
        .rig("crop-box")
    }

    /// The eight handles, as view points: four corners and four edge middles.
    private func handles(_ b: CGRect) -> [CGPoint] {
        let xs = [b.minX, b.midX, b.maxX], ys = [b.minY, b.midY, b.maxY]
        return xs.flatMap { x in ys.map { CGPoint(x: x, y: $0) } }.filter { !($0.x == b.midX && $0.y == b.midY) }
    }

    private func hit(_ p: CGPoint, box: CGRect) -> Grab {
        let nearL = abs(p.x - box.minX) < Self.reach, nearR = abs(p.x - box.maxX) < Self.reach
        let nearT = abs(p.y - box.minY) < Self.reach, nearB = abs(p.y - box.maxY) < Self.reach
        let withinX = p.x > box.minX - Self.reach && p.x < box.maxX + Self.reach
        let withinY = p.y > box.minY - Self.reach && p.y < box.maxY + Self.reach
        if (nearL || nearR) && (nearT || nearB) { return .corner(nearL, nearT) }
        if nearL && withinY { return .edge(horizontal: false, first: true) }
        if nearR && withinY { return .edge(horizontal: false, first: false) }
        if nearT && withinX { return .edge(horizontal: true, first: true) }
        if nearB && withinX { return .edge(horizontal: true, first: false) }
        return .inside
    }

    /// `s` with the grabbed part moved by (dx, dy) in photo fractions, kept inside the photo and `smallest` wide.
    private func moved(_ s: CropRect, _ g: Grab, _ dx: Double, _ dy: Double) -> CropRect {
        var l = s.left, t = s.top, r = s.right, b = s.bottom
        func lo(_ v: Double, _ other: Double) -> Double { min(max(v, 0), other - Self.smallest) }
        func hi(_ v: Double, _ other: Double) -> Double { max(min(v, 1), other + Self.smallest) }
        switch g {
        case .inside:
            let w = r - l, h = b - t
            l = min(max(l + dx, 0), 1 - w); r = l + w
            t = min(max(t + dy, 0), 1 - h); b = t + h
        case .corner(let left, let top):
            if left { l = lo(l + dx, r) } else { r = hi(r + dx, l) }
            if top { t = lo(t + dy, b) } else { b = hi(b + dy, t) }
        case .edge(let horizontal, let first):
            switch (horizontal, first) {
            case (false, true): l = lo(l + dx, r)
            case (false, false): r = hi(r + dx, l)
            case (true, true): t = lo(t + dy, b)
            case (true, false): b = hi(b + dy, t)
            }
        }
        return CropRect(left: l, top: t, right: r, bottom: b)
    }
}
