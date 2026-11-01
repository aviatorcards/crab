import SwiftUI

@main
struct CrabApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Crab", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showSettingsDialog = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Boot Image…") { model.showImagePicker = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.reload() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
