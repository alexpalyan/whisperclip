import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
            HotkeySettingsView(settings: settings)
            MeetingsSettingsView(settings: settings)
            PromptsSettingsView(settings: settings)
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
