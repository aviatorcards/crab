import CrabKit
import SwiftUI

struct ImageListView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete: ImageEntry?
    @State private var choosingFolder = false

    var body: some View {
        Group {
            if model.images.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "opticaldisc")
                } description: {
                    Text("There are no .iso or .img files in \(model.searchDirDisplay). Download one from Get Distros, or choose another folder.")
                } actions: {
                    Button("Choose Folder…") { choosingFolder = true }
                }
            } else {
                List(model.images) { img in
                    ImageRow(img: img)
                        .contextMenu {
                            Button("Boot") { model.bootImage(img.path) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([img.path])
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) { confirmDelete = img }
                        }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Label(model.searchDirDisplay, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(model.images.count) files, \(fmtKB(model.images.reduce(0) { $0 + $1.sizeKB }))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change Folder…") { choosingFolder = true }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.setSearchDir(url)
            }
        }
        .fileDialogDefaultDirectory(model.paths.searchDir)
        .confirmationDialog(
            "Move \(confirmDelete?.name ?? "") to the Trash?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { img in
            Button("Move to Trash", role: .destructive) { model.deleteImage(img.path) }
        } message: { img in
            Text("This moves the \(img.sizeHuman) file to the Trash. You can download it again from Get Distros if it came from there.")
        }
    }
}

private struct ImageRow: View {
    @Environment(AppModel.self) private var model
    let img: ImageEntry

    var body: some View {
        let booting = model.booting.contains(img.path.path)

        HStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(img.name)
                        .font(.headline)
                    Tag(img.sizeHuman, color: .gray)
                    if let booted = img.lastBootedSecs {
                        Tag("booted \(fmtAge(booted))", color: .green)
                    }
                }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if booting {
                ProgressView()
                    .controlSize(.small)
            }
            Button(bootLabel) { model.bootImage(img.path) }
                .buttonStyle(.borderedProminent)
                .disabled(booting)
        }
        .padding(.vertical, 6)
    }

    private var bootLabel: String {
        model.keep ? "Boot & Keep" : model.live ? "Boot Live" : "Boot Throwaway"
    }

    private var details: String {
        var s = "downloaded \(fmtAge(img.downloadedSecs))"
        if !img.fileInfo.isEmpty {
            s += " · \(img.fileInfo)"
        }
        return s
    }
}
