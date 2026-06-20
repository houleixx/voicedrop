import SwiftUI

/// Two tabs: the recorder and the library of recordings + mined articles.
struct RootView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            Tab("录音", systemImage: "mic.fill", value: 0) {
                ContentView()
            }
            Tab("文章", systemImage: "books.vertical.fill", value: 1) {
                // `active` flips true when this tab is selected → LibraryView
                // pulls fresh data from the server each time you switch to it.
                LibraryView(active: selection == 1)
            }
            Tab("设置", systemImage: "gearshape", value: 2) {
                SettingsView(active: selection == 2)
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }
}
