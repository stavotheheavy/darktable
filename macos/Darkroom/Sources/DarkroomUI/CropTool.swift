import DarkroomCore
import SwiftUI

/// The crop tool, a dropdown under the header's crop button (owner, 2026-10-22: crop is a tool, not a module). Straighten, turn and
/// flip, the aspect presets, and the four crop edges by hand. It writes the same crop, ashift and flip parameters as Simple
/// mode's controls (SimpleGeometry.swift), one history step per press.
struct CropTool: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Straighten")
            HStack {
                Slider(value: Binding(get: { model.simpleStraighten }, set: { model.setStraighten($0) }),
                       in: DarkroomModel.straightenRange, step: 0.1, onEditingChanged: { model.setDragging($0) })
                    .tint(Theme.accent)
                    .accessibilityLabel("Straighten")
                    .rig("crop-straighten")
                Text(String(format: "%+.1f\u{00B0}", model.simpleStraighten)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 8)

            heading("Turn and flip")
            HStack(spacing: 6) {
                tile("rotate.left", "Turn left", "crop-turn-left") { model.turn(.rotateCCW90, label: "Rotate left") }
                tile("rotate.right", "Turn right", "crop-turn-right") { model.turn(.rotateCW90, label: "Rotate right") }
                tile("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally", "crop-flip-h") { model.turn(.flipHorizontal, label: "Flip horizontally") }
                tile("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically", "crop-flip-v") { model.turn(.flipVertical, label: "Flip vertically") }
            }
            .padding(.horizontal, 8)

            heading("Crop to")
            HStack(spacing: 6) {
                ForEach(SimpleAspect.allCases) { a in
                    Button { model.setAspect(a) } label: {
                        Text(a.rawValue).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(model.simpleAspect == a ? Theme.selectedFill : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.spoken)
                    .accessibilityAddTraits(model.simpleAspect == a ? .isSelected : [])
                    .rig("crop-aspect-\(a.slug)")
                }
            }
            .padding(.horizontal, 8)

            heading("Edges")
            VStack(alignment: .leading, spacing: 0) {
                if let crop = model.proModule("crop"), model.schema(for: crop) != nil {
                    ParamList(model: model, module: crop)
                } else {
                    ProgressView().padding(8)
                }
            }
            .padding(.horizontal, 8)

            HStack {
                Spacer()
                Button("Reset") { model.resetGeometry() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(!model.geometryEdited)
                    .help("Crop, straighten, turn and flip back to nothing")
                    .rig("crop-reset")
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
        }
        .disabled(!model.simpleGeometryReady)
        .opacity(model.simpleGeometryReady ? 1 : 0.5)
        .task { await model.prepareSimple() }
    }

    private func tile(_ symbol: String, _ label: String, _ rig: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .rig(rig)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, design: .monospaced)).tracking(0.9).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}
