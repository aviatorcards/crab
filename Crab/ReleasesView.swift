import CrabKit
import SwiftUI

struct ReleasesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let entries = model.catalog.filter { $0.arch == model.arch }
        let grouped = Dictionary(grouping: entries, by: \.distro)

        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Releases", systemImage: "arrow.down.circle")
                } description: {
                    Text("Check for the current releases of \(distroSources.map(\.displayName).joined(separator: ", ")) for \(model.arch).")
                } actions: {
                    Button("Check for Releases") { model.syncCatalog() }
                        .disabled(model.busy)
                }
            } else {
                List {
                    ForEach(distros.filter { grouped[$0] != nil }, id: \.self) { distro in
                        Section(distroDisplayName(distro)) {
                            ForEach(grouped[distro] ?? []) { entry in
                                ReleaseRow(entry: entry)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("Saved to \(model.searchDirDisplay). SHA-256 when the project publishes one; SHA-1 for macOS restore images.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Picker("Architecture", selection: $model.arch) {
                    Text("arm64").tag("arm64")
                    Text("amd64").tag("amd64")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button(model.busy ? "Checking…" : "Check for Updates") { model.syncCatalog() }
                    .disabled(model.busy)
                    .help(model.catalogAge.map { "Last checked \($0)" } ?? "Never checked")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct ReleaseRow: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let downloaded = model.isDownloaded(entry)
        let downloading = model.download != nil
        let verifiable = !entry.sha256.isEmpty || !entry.sha1.isEmpty

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(entry.distro)/\(entry.variant)")
                        .font(.headline)
                    Tag("v\(entry.version)", color: .gray)
                    if entry.variant == defaultVariant(entry.distro) {
                        Tag("default", color: .blue)
                    }
                    if downloaded {
                        Tag("downloaded", color: .green)
                    }
                    if entry.sha256.isEmpty && entry.sha1.isEmpty {
                        Tag("unverified", color: .orange)
                            .help(entry.distro == macosDistro
                                ? "Apple didn't publish a checksum for this restore image. The installer rejects a damaged one."
                                : "This project doesn't publish checksums, so the download can't be verified")
                    }
                }
                Text(getFilename(distro: entry.distro, arch: entry.arch, url: entry.url))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(downloaded ? "Verify" : "Download") {
                model.downloadRelease(entry, bootAfter: false)
            }
            .disabled(downloading || (downloaded && !verifiable))
            .help(downloaded ? "Check the downloaded file against the release checksum" : "Download without booting")
            Button(downloaded ? "Boot" : "Get & Boot") {
                model.downloadRelease(entry, bootAfter: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(downloading)
            .help(entry.distro == macosDistro ? "Download Apple's restore image and install it in a throwaway macOS VM" : "Boot in a throwaway VM")
        }
        .padding(.vertical, 4)
    }
}
