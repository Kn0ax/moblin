import SwiftUI

struct StreamWhipSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var stream: SettingsStream

    var body: some View {
        Form {
            Section {
                TextField("Bearer token (optional)", text: $stream.whip.bearerToken)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .disabled(stream.enabled && model.isLive)
                    .onChange(of: stream.whip.bearerToken) { _ in
                        model.reloadStreamIfEnabled(stream: stream)
                    }
            } footer: {
                Text(
                    "Optional token sent as Authorization: Bearer <token> when connecting to the WHIP server."
                )
            }
        }
        .navigationTitle("WHIP")
    }
}
