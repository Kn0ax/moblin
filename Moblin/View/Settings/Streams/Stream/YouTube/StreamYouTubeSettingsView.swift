import SwiftUI

struct StreamYouTubeSettingsView: View {
    @EnvironmentObject var model: Model
    var stream: SettingsStream

    func submitVideoId(value: String) {
        stream.youTubeVideoId = value
        if stream.enabled {
            model.youTubeVideoIdUpdated()
        }
    }

    func submitHandle(value: String) {
        stream.youTubeHandle = value
        if stream.enabled {
            model.youTubeVideoIdUpdated() // Reuse the same update method
        }
    }

    var body: some View {
        Form {
            Section {
                TextEditNavigationView(
                    title: String(localized: "Channel handle"),
                    value: stream.youTubeHandle,
                    onSubmit: submitHandle
                )
            } header: {
                Text("Handle (Recommended)")
            } footer: {
                VStack(alignment: .leading) {
                    Text("Very experimental and very secret!")
                    Text("")
                    Text("Enter your YouTube channel gandle (e.g., @Ludwig).")
                    Text("We'll automatically detect if you're live.")
                }
            }
            // New reload button section
            Section {
                Button(action: {
                    model.youTubeVideoIdUpdated()
                }, label: {
                    Text("Try to retrieve chat")
                })
            }

            Section {
                TextEditNavigationView(
                    title: String(localized: "Video id"),
                    value: stream.youTubeVideoId,
                    onSubmit: submitVideoId
                )
            } header: {
                Text("Manual Video ID (Advanced)")
            } footer: {
                VStack(alignment: .leading) {
                    Text("The video id is the last part in your live streams URL.")
                    Text("Only use this if handle detection doesn't work.")
                }
            }
        }
        .navigationTitle("YouTube")
    }
}
