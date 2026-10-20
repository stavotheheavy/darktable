import SwiftUI

/// Placeholder until the curve-editor card lands: the five node heights as sliders.
struct CurveEditor: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                Slider(value: Binding(get: { model.curveNodes?[i] ?? Double(i) / 4 }, set: { model.setCurveNode(i, $0) }),
                       in: 0...1, onEditingChanged: { model.setDragging($0) })
            }
        }
    }
}
