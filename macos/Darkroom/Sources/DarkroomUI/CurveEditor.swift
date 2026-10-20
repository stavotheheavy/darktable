import DarkroomCore
import SwiftUI

/// Pro's tone curve: a point curve you shape with the pointer. Drag a point anywhere (left, right, up, down; it stops at its
/// neighbours so the curve never folds back), click the curve to add a point, double-click a point (or press Delete on it) to
/// remove it, drag an end point to set a black or white point. The arrow keys nudge the focused point. Eight points at most.
/// The plot is inset so the points at the corners sit fully inside it, where they can be grabbed.
struct CurveEditor: View {
    @Bindable var model: DarkroomModel
    /// The point the pointer is holding, and the one the keyboard is on.
    @State private var grabbed: Int?
    @FocusState private var focusedPoint: Int?

    private static let identity = [DarkroomModel.CurvePoint(x: 0, y: 0), .init(x: 0.25, y: 0.25), .init(x: 0.5, y: 0.5), .init(x: 0.75, y: 0.75), .init(x: 1, y: 1)]

    var body: some View {
        let live = model.curvePoints != nil
        let pts = model.curvePoints ?? Self.identity
        VStack(spacing: 6) {
            GeometryReader { geo in
                let plot = CurveGeometry.plot(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in Self.draw(&ctx, plot: plot, points: pts) }
                    ForEach(pts.indices, id: \.self) { i in handle(i, pts: pts, plot: plot) }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(drag(plot: plot))
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                    let now = model.curvePoints ?? pts
                    if let i = CurveGeometry.nearestPoint(to: v.location, in: now, plot: plot), (1..<(now.count - 1)).contains(i) {
                        model.removeCurvePoint(i)
                    }
                })
            }
            .frame(height: 196)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            Text(readout(pts))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .disabled(!live)
        .opacity(live ? 1 : 0.5)
        .rig("pro-curve")
        .onAppear {
            if Rig.enabled {
                for i in 0..<ToneCurve.maxPoints { Rig.setters["pro-curve-node-\(i)"] = { frac in model.setCurveNode(i, frac) } }
            }
        }
    }

    private func readout(_ pts: [DarkroomModel.CurvePoint]) -> String {
        if let i = grabbed ?? focusedPoint, pts.indices.contains(i) {
            return String(format: "point %d of %d   in %.0f%%   out %.0f%%", i + 1, pts.count, pts[i].x * 100, pts[i].y * 100)
        }
        return "\(pts.count) points \u{00B7} click the curve to add one \u{00B7} double-click a point to remove it"
    }

    // MARK: drawing

    private static func draw(_ ctx: inout GraphicsContext, plot: CGRect, points: [DarkroomModel.CurvePoint]) {
        func at(_ x: Double, _ y: Double) -> CGPoint { CurveGeometry.view(.init(x: x, y: y), plot: plot) }
        var grid = Path()
        for k in 1...3 {
            let f = Double(k) / 4
            grid.move(to: at(f, 0)); grid.addLine(to: at(f, 1))
            grid.move(to: at(0, f)); grid.addLine(to: at(1, f))
        }
        ctx.stroke(grid, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
        ctx.stroke(Path(plot), with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        var diagonal = Path()
        diagonal.move(to: at(0, 0)); diagonal.addLine(to: at(1, 1))
        ctx.stroke(diagonal, with: .color(Color.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        let xs = points.map(\.x), ys = points.map(\.y), m = ToneCurve.tangents(xs: xs, ys: ys)
        var curve = Path()
        for s in 0...120 {
            let e = Double(s) / 120
            let v = min(max(ToneCurve.curve(e, xs: xs, ys: ys, tangents: m), 0), 1)
            if s == 0 { curve.move(to: at(e, v)) } else { curve.addLine(to: at(e, v)) }
        }
        ctx.stroke(curve, with: .color(Theme.accent), lineWidth: 2)
    }

    /// One point: drawn only (the drag gesture does the grabbing), but focusable so the keyboard can reach it.
    private func handle(_ i: Int, pts: [DarkroomModel.CurvePoint], plot: CGRect) -> some View {
        let active = grabbed == i || focusedPoint == i
        let d: CGFloat = active ? 18 : 14
        let p = pts[i]
        return Circle()
            .fill(active ? Theme.accent.opacity(0.35) : Color.black.opacity(0.6))
            .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
            .frame(width: d, height: d)
            .frame(width: 28, height: 28)
            .position(CurveGeometry.view(p, plot: plot))
            .allowsHitTesting(false)
            .focusable()
            .focused($focusedPoint, equals: i)
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .delete, .deleteForward]) { event in
                guard let current = model.curvePoints, current.indices.contains(i) else { return .ignored }
                let step = event.modifiers.contains(.shift) ? 0.05 : 0.01
                let which = event.key
                if which == .delete || which == .deleteForward { model.removeCurvePoint(i); return .handled }
                model.beginCurveDrag()
                switch which {
                case .upArrow: model.moveCurvePoint(i, x: current[i].x, y: current[i].y + step)
                case .downArrow: model.moveCurvePoint(i, x: current[i].x, y: current[i].y - step)
                case .leftArrow: model.moveCurvePoint(i, x: current[i].x - step, y: current[i].y)
                default: model.moveCurvePoint(i, x: current[i].x + step, y: current[i].y)
                }
                return .handled
            }
            .accessibilityLabel("Point \(i + 1) of \(pts.count)")
            .accessibilityValue(String(format: "in %.0f percent, out %.0f percent", p.x * 100, p.y * 100))
            .accessibilityAdjustableAction { direction in
                model.beginCurveDrag()
                switch direction {
                case .increment: model.moveCurvePoint(i, x: p.x, y: p.y + 0.01)
                case .decrement: model.moveCurvePoint(i, x: p.x, y: p.y - 0.01)
                default: break
                }
            }
    }

    // MARK: the gesture

    /// Takes the point under the pointer (or adds one where the pointer lands on the curve) and moves it with the pointer in x
    /// and y. A drag is one history step.
    private func drag(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if grabbed == nil {
                    guard let pts = model.curvePoints else { return }
                    model.beginCurveDrag()
                    switch CurveGeometry.grab(at: v.startLocation, points: pts, plot: plot) {
                    case .point(let i): grabbed = i
                    case .insert(let x, let y): grabbed = model.insertCurvePoint(x: x, y: y)
                    case .none: return
                    }
                    if grabbed == nil { return }
                    focusedPoint = grabbed
                    model.setDragging(true)
                }
                guard let i = grabbed else { return }
                let now = CurveGeometry.value(v.location, plot: plot)
                model.moveCurvePoint(i, x: now.x, y: now.y)
            }
            .onEnded { _ in
                if grabbed != nil { model.setDragging(false) }
                grabbed = nil
            }
    }
}

/// The curve editor's geometry for a single vertical axis, kept apart from the view so the maths can be checked without a screen.
public enum CurveGeometry {
    /// Space kept round the plot so the points at its corners are drawn and grabbed whole.
    public static let inset: CGFloat = 16
    /// How close, in points, the pointer must be to a point to take it, or to the curve to add a point.
    public static let grabRadius: CGFloat = 22
    public static let curveRadius: CGFloat = 14

    public static func plot(in size: CGSize) -> CGRect {
        CGRect(x: inset, y: inset, width: max(1, size.width - 2 * inset), height: max(1, size.height - 2 * inset))
    }

    /// Where a curve point sits in the view.
    public static func view(_ p: DarkroomModel.CurvePoint, plot: CGRect) -> CGPoint {
        CGPoint(x: plot.minX + CGFloat(p.x) * plot.width, y: plot.minY + CGFloat(1 - p.y) * plot.height)
    }

    /// The curve value (0...1 each) under a view point.
    public static func value(_ q: CGPoint, plot: CGRect) -> (x: Double, y: Double) {
        (min(max(Double((q.x - plot.minX) / plot.width), 0), 1), min(max(1 - Double((q.y - plot.minY) / plot.height), 0), 1))
    }

    /// The point whose centre is within `grabRadius` of `q`, nearest first.
    public static func nearestPoint(to q: CGPoint, in pts: [DarkroomModel.CurvePoint], plot: CGRect) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in pts.enumerated() {
            let v = view(p, plot: plot), d = hypot(v.x - q.x, v.y - q.y)
            if d <= grabRadius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// The curve's height (0...1) at x, as the engine evaluates it in the encoded domain.
    public static func curveHeight(at x: Double, points: [DarkroomModel.CurvePoint]) -> Double {
        let xs = points.map(\.x), ys = points.map(\.y)
        return min(max(ToneCurve.curve(x, xs: xs, ys: ys, tangents: ToneCurve.tangents(xs: xs, ys: ys)), 0), 1)
    }

    /// What pressing the pointer at `q` does: take a point, add one on the curve, or nothing.
    public enum Grab: Equatable { case point(Int), insert(x: Double, y: Double), none }

    public static func grab(at q: CGPoint, points: [DarkroomModel.CurvePoint], plot: CGRect) -> Grab {
        if let i = nearestPoint(to: q, in: points, plot: plot) { return .point(i) }
        let at = value(q, plot: plot), height = curveHeight(at: at.x, points: points)
        guard abs(view(.init(x: at.x, y: height), plot: plot).y - q.y) <= curveRadius else { return .none }
        return .insert(x: at.x, y: height)
    }

    /// The node height under a pointer at vertical position `y`; the top of the plot is 1, the bottom 0.
    public static func height(atY y: CGFloat, plotTop: CGFloat, plotHeight: CGFloat) -> Double {
        guard plotHeight > 0 else { return 0 }
        return min(max(1 - Double((y - plotTop) / plotHeight), 0), 1)
    }

    /// The vertical position of a node at height `h`.
    public static func y(forHeight h: Double, plotTop: CGFloat, plotHeight: CGFloat) -> CGFloat {
        plotTop + CGFloat(1 - h) * plotHeight
    }

    /// The node (0...4) whose x is nearest `x`, on the five-position layout the first version of the curve had.
    public static func nearestNode(toX x: CGFloat, plotLeft: CGFloat, plotWidth: CGFloat) -> Int {
        guard plotWidth > 0 else { return 0 }
        return Int(min(max(((x - plotLeft) / plotWidth * 4).rounded(), 0), 4))
    }
}
