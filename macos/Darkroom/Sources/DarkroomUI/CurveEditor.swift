import DarkroomCore
import SwiftUI

/// Pro's tone curve, drawn as the engine applies it: five nodes at x = 0, 0.25, 0.5, 0.75, 1, joined by the
/// same monotone curve ToneCurve evaluates. Drag a node up or down; the arrow keys nudge the focused one.
struct CurveEditor: View {
    @Bindable var model: DarkroomModel
    /// The node a drag is moving, chosen where the drag starts. The gesture resets it when the drag ends or is cancelled.
    @GestureState private var activeNode: Int?
    @FocusState private var focusedNode: Int?

    private static let flat = [0.0, 0.25, 0.5, 0.75, 1.0]

    var body: some View {
        let live = model.curveNodes != nil
        let ys = model.curveNodes ?? Self.flat
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, canvasSize in Self.draw(&ctx, size: canvasSize, ys: ys) }
                ForEach(0..<5, id: \.self) { i in handle(i, ys: ys, size: size) }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(drag(size: size))
        }
        .padding(12)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .disabled(!live)
        .opacity(live ? 1 : 0.5)
        .onChange(of: activeNode) { old, new in
            if let new { focusedNode = new }
            // paired with the start in drag(size:): a cancelled drag resets the node too, so this still runs
            if old != nil && new == nil { model.setDragging(false) }
        }
        .rig("pro-curve")
        .onAppear {
            if Rig.enabled {
                for i in 0..<5 {
                    Rig.setters["pro-curve-node-\(i)"] = { frac in model.setCurveNode(i, frac) }
                }
            }
        }
    }

    /// The grid, the identity diagonal and the curve, in the plot's own coordinates (y up).
    private static func draw(_ ctx: inout GraphicsContext, size: CGSize, ys: [Double]) {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: CGFloat(x) * size.width, y: CurveGeometry.y(forHeight: y, plotTop: 0, plotHeight: size.height))
        }
        var grid = Path()
        for k in 1...3 {
            let f = Double(k) / 4
            grid.move(to: point(f, 0))
            grid.addLine(to: point(f, 1))
            grid.move(to: point(0, f))
            grid.addLine(to: point(1, f))
        }
        ctx.stroke(grid, with: .color(Color.white.opacity(0.08)), lineWidth: 1)

        var diagonal = Path()
        diagonal.move(to: point(0, 0))
        diagonal.addLine(to: point(1, 1))
        ctx.stroke(diagonal, with: .color(Color.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        let tangents = ToneCurve.tangents(ys)
        var curve = Path()
        for s in 0...100 {
            let e = Double(s) / 100
            let v = min(max(ToneCurve.curve(e, ys: ys, tangents: tangents), 0), 1)
            if s == 0 {
                curve.move(to: point(e, v))
            } else {
                curve.addLine(to: point(e, v))
            }
        }
        ctx.stroke(curve, with: .color(Theme.accent), lineWidth: 2)
    }

    /// One node: a 28 pt hit area around a circle of radius 7 (9 while it is dragged or focused).
    private func handle(_ i: Int, ys: [Double], size: CGSize) -> some View {
        let active = activeNode == i || focusedNode == i
        let d: CGFloat = active ? 18 : 14
        return Circle()
            .fill(Color.black.opacity(0.6))
            .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
            .frame(width: d, height: d)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .position(x: CGFloat(i) / 4 * size.width,
                      y: CurveGeometry.y(forHeight: ys[i], plotTop: 0, plotHeight: size.height))
            .focusable()
            .focused($focusedNode, equals: i)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let step = press.modifiers.contains(.shift) ? 0.05 : 0.01
                model.setCurveNode(i, ys[i] + (press.key == .upArrow ? step : -step))
                return .handled
            }
            .accessibilityLabel("Point \(i + 1) of 5")
            .accessibilityValue("\(Int((ys[i] * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.setCurveNode(i, ys[i] + 0.01)
                case .decrement: model.setCurveNode(i, ys[i] - 0.01)
                default: break
                }
            }
    }

    /// Vertical only: the node nearest the start of the drag follows the pointer's height. One drag is one history step.
    /// A 3 pt move is needed to start, so a plain click (which may only mean focus) changes nothing.
    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($activeNode) { value, node, _ in
                if node == nil {
                    node = CurveGeometry.nearestNode(toX: value.startLocation.x, plotLeft: 0, plotWidth: size.width)
                    model.setDragging(true)
                }
                guard let i = node else { return }
                model.setCurveNode(i, CurveGeometry.height(atY: value.location.y, plotTop: 0, plotHeight: size.height))
            }
    }
}

/// The curve editor's geometry, kept apart from the view so the maths can be checked without a screen.
public enum CurveGeometry {
    /// The node height under a pointer at vertical position `y`; the top of the plot is 1, the bottom 0.
    public static func height(atY y: CGFloat, plotTop: CGFloat, plotHeight: CGFloat) -> Double {
        guard plotHeight > 0 else { return 0 }
        return min(max(1 - Double((y - plotTop) / plotHeight), 0), 1)
    }

    /// The vertical position of a node at height `h`.
    public static func y(forHeight h: Double, plotTop: CGFloat, plotHeight: CGFloat) -> CGFloat {
        plotTop + CGFloat(1 - h) * plotHeight
    }

    /// The node (0...4) whose x is nearest `x`.
    public static func nearestNode(toX x: CGFloat, plotLeft: CGFloat, plotWidth: CGFloat) -> Int {
        guard plotWidth > 0 else { return 0 }
        return Int(min(max(((x - plotLeft) / plotWidth * 4).rounded(), 0), 4))
    }
}
