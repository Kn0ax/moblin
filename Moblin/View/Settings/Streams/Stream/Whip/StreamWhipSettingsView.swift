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
                    .disabled(isLocked)
                    .onChange(of: stream.whip.bearerToken) { _ in
                        model.reloadStreamIfEnabled(stream: stream)
                    }
            } footer: {
                Text(
                    "Optional token sent as Authorization: Bearer <token> when connecting to the WHIP server."
                )
            }
            Section {
                ForEach(Array(stream.whip.stunServers.indices), id: \.self) { index in
                    TextField("stun:stun.example.com:3478", text: stunServerBinding(index))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .disabled(isLocked)
                }
                .onDelete(perform: deleteStunServers)

                Button {
                    stream.whip.stunServers.append("")
                    model.reloadStreamIfEnabled(stream: stream)
                } label: {
                    Label("Add STUN server", systemImage: "plus")
                }
                .disabled(isLocked)
            } footer: {
                Text(
                    "Optional STUN server list. Example: stun:stun.example.com:3478"
                )
            }
        }
        .navigationTitle("WHIP")
    }

    private var isLocked: Bool {
        stream.enabled && model.isLive
    }

    private func stunServerBinding(_ index: Int) -> Binding<String> {
        return Binding(
            get: {
                stream.whip.stunServers[index]
            },
            set: { newValue in
                stream.whip.stunServers[index] = newValue
                model.reloadStreamIfEnabled(stream: stream)
            }
        )
    }

    private func deleteStunServers(at offsets: IndexSet) {
        stream.whip.stunServers.remove(atOffsets: offsets)
        model.reloadStreamIfEnabled(stream: stream)
    }
}
