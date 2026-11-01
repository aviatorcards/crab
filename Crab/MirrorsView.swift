import CrabKit
import SwiftUI

struct MirrorsView: View {
    @Environment(AppModel.self) private var model
    @State private var mirrorHost = ""
    @State private var officialPrefix = ""
    @State private var rssURL = defaultRSSFeed
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                TextField("Mirror", text: $mirrorHost, prompt: Text("mirrors.rit.edu or https://mirror.example.edu/ubuntu-releases/"))
                TextField("Official prefix", text: $officialPrefix, prompt: Text("Optional, e.g. https://releases.ubuntu.com/"))
                HStack {
                    Spacer()
                    Button(officialPrefix.isEmpty ? "Probe & Add" : "Add Rule") {
                        model.addMirror(host: mirrorHost, official: officialPrefix)
                        mirrorHost = ""
                        officialPrefix = ""
                    }
                    .disabled(mirrorHost.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
            } header: {
                Text("Add a Mirror")
            } footer: {
                Text("With just a mirror host, crab reads its index to find Fedora, Ubuntu, Alpine and OpenBSD trees. With an official prefix too, it adds that one rule.")
            }

            Section {
                ForEach(model.mirrors, id: \.self) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.mirror)
                            Text("for \(rule.official)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { model.removeMirror(rule) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove every rule using this mirror")
                    }
                }
            } header: {
                HStack {
                    Text("Mirror Rules")
                    Spacer()
                    Button("Reset to Defaults") { confirmReset = true }
                        .controlSize(.small)
                }
            } footer: {
                Text("Downloads try these mirrors in order, then the official site. Saved in \(model.vmRootDisplay)/mirrors.")
            }

            Section("Release News") {
                HStack {
                    TextField("Feed", text: $rssURL)
                        .labelsHidden()
                        .onSubmit { model.fetchRSS(rssURL) }
                    Button("Fetch") { model.fetchRSS(rssURL) }
                        .disabled(model.busy)
                }
                ForEach(Array(model.rssItems.prefix(15).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        if let url = URL(string: item.link), !item.link.isEmpty {
                            Link(item.title, destination: url)
                        } else {
                            Text(item.title)
                        }
                        if !item.pubDate.isEmpty {
                            Text(item.pubDate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset mirrors to the built-in defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetMirrors() }
        } message: {
            Text("Mirrors you've added are removed.")
        }
    }
}
