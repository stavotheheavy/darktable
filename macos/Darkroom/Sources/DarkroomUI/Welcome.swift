import DarkroomEngineAPI
import SwiftUI
import UniformTypeIdentifiers

/// First launch (canvas boards P1 and A1): sign-in is shown but not wired yet, then the
/// mode choice, then the first folder. Everything here is stored on this Mac only.
struct WelcomeView: View {
    enum Step: Int, CaseIterable { case account, mode, folder }

    let finish: (EditMode, URL?) -> Void
    @State private var step = Step.account
    @State private var mode = EditMode.simple
    @State private var choosing = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(Step.allCases, id: \.rawValue) { s in
                        Capsule().fill(s.rawValue <= step.rawValue ? Theme.accent : Color.white.opacity(0.3))
                            .frame(width: s == step ? 28 : 6, height: 6)
                            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22), value: step)
                    }
                    Spacer()
                }
                .padding(.bottom, 26)

                switch step {
                case .account: account
                case .mode: modeChoice
                case .folder: folder
                }
            }
            .padding(34)
            .frame(maxWidth: 600)
            .glassEffect(.regular, in: .rect(cornerRadius: 40))
            .padding(.horizontal, 16)
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { finish(mode, url) }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to Vantage").font(.largeTitle.weight(.semibold)).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
            Text("Sign in with your Databit Dev account to share galleries and sell photos. Editing works on \(Platform.thisDevice) without it.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(["Apple", "Google", "GitHub"], id: \.self) { p in
                    Text("Continue with \(p)").font(.callout.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .opacity(0.45)
                }
                Text("Sign-in arrives with sharing and selling.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 14)
            Button { step = .mode } label: { Text("Use Vantage on \(Platform.thisDevice)").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryCapsuleStyle())
                .padding(.top, 14)
                .rig("welcome-continue")
        }
    }

    private var modeChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How do you like to edit?").font(.largeTitle.weight(.semibold)).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
            Text("Change it any time from the header. Your edits carry across.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                card(.simple, "A few big sliders and one-tap looks.")
                card(.pro, "Every module, scopes, masks and history.")
            }
            .padding(.top, 14)
            Text("Not sure? Start with Simple. The switch is always in the header.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back") { step = .account }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button { step = .folder } label: { Text("Continue") }.buttonStyle(PrimaryCapsuleStyle())
                    .rig("welcome-mode-continue")
            }
            .padding(.top, 12)
        }
    }

    private func card(_ m: EditMode, _ blurb: String) -> some View {
        Button { mode = m } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.rawValue).font(.title3.weight(.semibold))
                Text(blurb).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(mode == m ? Theme.selectedFill : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(mode == m ? Theme.selectedRing : Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .rig("welcome-\(m.rawValue.lowercased())")
        .accessibilityAddTraits(mode == m ? .isSelected : [])
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where are your photos?").font(.largeTitle.weight(.semibold)).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            Text("Pick photos from your Photos library, Files, iCloud Drive, Google Drive, Dropbox and other cloud apps on the next screen. Vantage keeps a copy inside the app. Your originals stay where they are and nothing is uploaded.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") { step = .mode }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button { finish(mode, nil) } label: { Text("Add photos") }.buttonStyle(PrimaryCapsuleStyle())
                    .rig("welcome-folder")
            }
            .padding(.top, 20)
            #else
            Text("Originals stay where they are. Nothing is uploaded. Soft frames and near-duplicates are flagged as the folder loads.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") { step = .mode }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Later") { finish(mode, nil) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
                Button { choosing = true } label: { Text("Choose a folder") }.buttonStyle(PrimaryCapsuleStyle())
                    .rig("welcome-folder")
            }
            .padding(.top, 20)
            #endif
        }
    }
}
