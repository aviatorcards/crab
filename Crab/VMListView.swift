import CrabKit
import SwiftUI

struct VMListView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshotsFor: VMEntry?
    @State private var confirmDelete: VMEntry?
    @State private var nameEdit: NameEdit?

    var body: some View {
        Group {
            if model.vms.isEmpty {
                ContentUnavailableView(
                    "No Saved VMs",
                    systemImage: "desktopcomputer",
                    description: Text("Boot an image and keep it when the VM closes, or choose “Save permanently” in the launch settings. VMs live in \(model.vmRootDisplay).")
                )
            } else {
                List(model.vms) { vm in
                    VMRow(vm: vm, onSnapshots: { snapshotsFor = vm }, onDelete: { confirmDelete = vm })
                        .contextMenu {
                            Button("Snapshots…") { snapshotsFor = vm }
                            Button("Clone…") { nameEdit = NameEdit(vm: vm, kind: .clone) }
                                .disabled(vm.runningPID != nil)
                            Button("Rename…") { nameEdit = NameEdit(vm: vm, kind: .rename) }
                                .disabled(vm.runningPID != nil)
                            Divider()
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([vm.dir])
                            }
                            if !vm.sshPort.isEmpty && vm.sshPort != "0" {
                                Button("Copy SSH Command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("crab ssh \(vm.name)", forType: .string)
                                }
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) { confirmDelete = vm }
                                .disabled(vm.runningPID != nil)
                        }
                }
            }
        }
        .sheet(item: $snapshotsFor) { vm in
            SnapshotsSheet(vm: vm)
        }
        .sheet(item: $nameEdit) { edit in
            NameEditSheet(edit: edit)
        }
        .confirmationDialog(
            "Delete \(confirmDelete?.name ?? "")?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { vm in
            Button("Delete VM", role: .destructive) { model.deleteVM(vm.name) }
        } message: { vm in
            Text("This deletes \(vm.dir.path) (\(vm.diskUsed)), including its disk and snapshots.")
        }
    }
}

private struct VMRow: View {
    @Environment(AppModel.self) private var model
    let vm: VMEntry
    let onSnapshots: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let running = vm.runningPID != nil
        let busy = model.vmOps.contains(vm.name) || model.booting.contains(vm.name)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: running ? "play.desktopcomputer" : "desktopcomputer")
                .font(.title2)
                .foregroundStyle(running ? .green : .secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(vm.name)
                        .font(.headline)
                    Tag(vm.arch.isEmpty ? "?" : vm.arch, color: .blue)
                    if !vm.firmware.isEmpty {
                        Tag(vm.firmware, color: .gray)
                    }
                    if running {
                        Tag(vm.state, color: .green)
                    }
                }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if busy {
                ProgressView()
                    .controlSize(.small)
            }
            if running {
                Button("Shut Down") { model.stopVM(vm.name) }
                    .disabled(busy)
                Button("Force Off", role: .destructive) { model.forceOffVM(vm.name) }
                    .disabled(busy)
            } else {
                Button("Snapshots (\(vm.snapsCount))", action: onSnapshots)
                Button("Boot") { model.bootVM(vm.name) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 6)
    }

    private var details: String {
        var parts = [
            "\(vm.mem) RAM",
            "\(vm.cpus) CPUs",
            "disk \(vm.diskUsed) of \(vm.diskVirt)",
            "used \(fmtAge(vm.lastUsedSecs))",
        ]
        if !vm.sshPort.isEmpty && vm.sshPort != "0" {
            parts.append("ssh localhost:\(vm.sshPort)")
        }
        return parts.joined(separator: " · ")
    }
}

/// A small capsule label, like "ARM64" or "UEFI".
struct Tag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }
}

struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vm: VMEntry
    @State private var snapshots: [String]?
    @State private var newTag = ""
    @State private var confirmRestore: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snapshots of \(vm.name)")
                .font(.title2.bold())
            HStack {
                TextField("Tag (defaults to a timestamp)", text: $newTag)
                    .onSubmit(create)
                Button("Take Snapshot", action: create)
                    .disabled(model.vmOps.contains(vm.name))
            }
            Group {
                if let snapshots, snapshots.isEmpty {
                    ContentUnavailableView("No Snapshots", systemImage: "camera")
                } else if let snapshots {
                    List(snapshots, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            Spacer()
                            Button("Restore…") { confirmRestore = tag }
                            Button("Delete", role: .destructive) {
                                model.deleteSnapshot(vm.name, tag: tag)
                            }
                        }
                        .disabled(model.vmOps.contains(vm.name))
                    }
                    .listStyle(.bordered)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 180)
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .task(id: model.vmOps.contains(vm.name)) {
            // Reload whenever an operation on this VM finishes.
            if !model.vmOps.contains(vm.name) {
                snapshots = await model.snapshots(of: vm)
            }
        }
        .confirmationDialog(
            "Roll \(vm.name) back to “\(confirmRestore ?? "")”?",
            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
            presenting: confirmRestore
        ) { tag in
            Button("Restore", role: .destructive) { model.restoreSnapshot(vm.name, tag: tag) }
        } message: { _ in
            Text("Changes since then are lost.")
        }
    }

    private func create() {
        model.createSnapshot(vm.name, tag: newTag)
        newTag = ""
    }
}

struct NameEdit: Identifiable {
    enum Kind { case clone, rename }
    let vm: VMEntry
    let kind: Kind
    var id: String { "\(vm.name)-\(kind)" }
}

private struct NameEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let edit: NameEdit
    @State private var name = ""

    var body: some View {
        Form {
            TextField(edit.kind == .clone ? "Name of the copy" : "New name", text: $name)
        }
        .formStyle(.grouped)
        .navigationTitle(edit.kind == .clone ? "Clone \(edit.vm.name)" : "Rename \(edit.vm.name)")
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(edit.kind == .clone ? "Clone" : "Rename") {
                    let newName = name.trimmingCharacters(in: .whitespaces)
                    switch edit.kind {
                    case .clone: model.cloneVM(edit.vm.name, to: newName)
                    case .rename: model.renameVM(edit.vm.name, to: newName)
                    }
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            name = edit.kind == .clone ? "\(edit.vm.name)-copy" : edit.vm.name
        }
    }
}
