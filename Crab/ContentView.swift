import CrabKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .vms
    @State private var showSettings = true

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.systemImage)
                    .badge(badge(for: page))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch page {
                case .vms: VMListView()
                case .images: ImageListView()
                case .releases: ReleasesView()
                case .mirrors: MirrorsView()
                }
            }
            .navigationTitle(page.title)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar()
            }
        }
        .inspector(isPresented: $showSettings) {
            LaunchSettingsView()
                .inspectorColumnWidth(min: 240, ideal: 270, max: 340)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Boot Image…", systemImage: "play.circle") {
                    model.showImagePicker = true
                }
                .help("Boot an .iso, .img, or macOS .ipsw with the launch settings")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.reload()
                }
                .help("Re-read VMs, images, releases and mirrors")
                Button("Settings…", systemImage: "gearshape") {
                    model.showSettingsDialog = true
                }
                .help("Open VM Manager Settings")
            }
            ToolbarItem {
                Button("Launch Settings", systemImage: "sidebar.trailing") {
                    showSettings.toggle()
                }
                .help("Show or hide the launch settings")
            }
        }
        .fileImporter(
            isPresented: $model.showImagePicker,
            allowedContentTypes: [.diskImage, UTType(filenameExtension: "iso") ?? .data, UTType(filenameExtension: "img") ?? .data, UTType(filenameExtension: "ipsw") ?? .data]
        ) { result in
            if case .success(let url) = result {
                model.bootImage(url)
            }
        }
        .sheet(item: $model.currentThrowaway) { prompt in
            ThrowawaySheet(prompt: prompt)
        }
        .sheet(isPresented: $model.showSettingsDialog) {
            SettingsView()
                .environment(model)
        }
        .task {
            model.reload()
            await model.pollStates()
        }
    }

    private func badge(for page: Page) -> Int {
        switch page {
        case .vms: model.vms.count
        case .images: model.images.count
        case .releases, .mirrors: 0
        }
    }
}

/// The status line and download progress along the bottom of the window.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let download = model.download {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Downloading \(download.label)")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text(amount(download))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let fraction = download.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        Text(download.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button("Cancel", role: .cancel) {
                        model.cancelDownload()
                    }
                    .disabled(download.cancel.isCancelled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            HStack {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button("Clean Up Scratch VMs") {
                    model.cleanScratch()
                }
                .controlSize(.small)
                .help("Delete throwaway VMs left behind by crashes")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func amount(_ d: ActiveDownload) -> String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        guard let total = d.total, total > 0 else { return fmt(d.done) }
        return "\(fmt(d.done)) of \(fmt(total)) (\(Int(Double(d.done) * 100 / Double(total)))%)"
    }
}
