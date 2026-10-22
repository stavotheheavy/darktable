import SwiftUI

/// The header's account button: sign in to Databit Dev, or who is signed in, whether Pro is on, and Sign out.
struct AccountMenu: View {
    @Bindable var model: DarkroomModel

    var body: some View {
        Menu {
            if let user = model.cloudUser {
                Text(user.name.map { "\($0) \u{00B7} \(user.email)" } ?? user.email)
                Text(model.cloudPro ? "Vantage Pro is on" : "Vantage Pro is not active")
                Divider()
                Button("Sign out") { Task { await model.signOutOfCloud() } }
            } else {
                Button("Sign in to Databit Dev\u{2026}") { Task { await model.signInToCloud() } }
            }
            if let message = model.cloudMessage { Divider(); Text(message) }
        } label: {
            Image(systemName: model.cloudSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .frame(width: 40, height: 40)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(model.cloudBusy)
        .help(model.cloudUser.map { "Signed in as \($0.email)" } ?? "Sign in to Databit Dev (\u{2325}\u{2318}U)")
        .accessibilityLabel(model.cloudSignedIn ? "Account" : "Sign in to Databit Dev")
        .rig("account")
    }
}
