import SwiftUI

/// The `?` overlay: every shortcut in the registry (Shortcuts.swift), grouped. Click outside it, press ? or Esc to close.
struct HelpOverlay: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.helpShown = false }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Keyboard shortcuts").font(.title3.weight(.semibold))
                    Spacer()
                    Button { model.helpShown = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Close shortcuts").rig("help-close")
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), alignment: .top)],
                              alignment: .leading, spacing: 18) {
                        ForEach(Shortcuts.groups, id: \.title) { g in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.title.uppercased())
                                    .font(.system(size: 10.5, design: .monospaced)).tracking(0.9).foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(g.shortcuts) { s in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(s.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 8)
                                        Text(s.keys)
                                            .font(.callout.monospaced()).padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                Text("Arrow keys, [ ], E, F and Delete work in Pro on the panel. They step aside while you type in a field.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 760, maxHeight: 560)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(24)
        }
        .rig("help-overlay")
        .accessibilityAddTraits(.isModal)
    }
}
