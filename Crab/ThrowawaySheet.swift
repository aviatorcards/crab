import SwiftUI

/// Asks what to do with a throwaway VM once its QEMU has exited.
struct ThrowawaySheet: View {
    @Environment(AppModel.self) private var model
    let prompt: ThrowawayPrompt
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.live ? "Live VM Exited" : "Throwaway VM Exited")
                .font(.title2.bold())

            if prompt.canKeep {
                Text("Its disk has \(prompt.diskSizeHuman) written to it. Keep it as a saved VM?")
                HStack {
                    TextField("Name", text: $name)
                        .onSubmit(keep)
                    Button("Keep", action: keep)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            HStack {
                if let image = prompt.imagePath, FileManager.default.fileExists(atPath: image.path) {
                    Button("Trash VM and \(image.lastPathComponent)", role: .destructive) {
                        model.discardThrowaway(prompt, deleteImage: true)
                    }
                }
                Spacer()
                Button("Trash VM", role: .destructive) {
                    model.discardThrowaway(prompt, deleteImage: false)
                }
                .keyboardShortcut(prompt.canKeep ? .cancelAction : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .onAppear { name = prompt.name }
    }

    private func keep() {
        if !model.keepThrowaway(prompt, as: name) {
            error = model.status
        }
    }
}
