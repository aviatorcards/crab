import SwiftUI
import CrabKit

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable {
        case general
        case display
        case advanced
    }

    @State private var selectedTab: Tab = .general

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header for dialog mode
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                    .tag(Tab.general)

                displayTab
                    .tabItem {
                        Label("Display & Hardware", systemImage: "display")
                    }
                    .tag(Tab.display)

                advancedTab
                    .tabItem {
                        Label("QEMU & Advanced", systemImage: "terminal")
                    }
                    .tag(Tab.advanced)
            }
            .padding(20)
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 460, idealHeight: 520)
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VM Library Location")
                                .font(.headline)
                            Text(model.paths.vmRoot.path)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Show in Finder") {
                            model.revealVMRoot()
                        }
                    }
                    Text("Directory where saved virtual machines, disks, and configs are stored.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Image Search Directory")
                                .font(.headline)
                            Text(model.paths.searchDir.path)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Change…") {
                            model.chooseSearchDirectory()
                        }
                        Button("Show in Finder") {
                            model.revealSearchDirectory()
                        }
                    }
                    Text("Folder scanned for bootable .iso and .img disk images.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Storage Locations")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Distro Catalog")
                            .font(.headline)
                        if let age = model.catalogAge {
                            Text("Last updated: \(age)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No local catalog cached yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.busy {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    Button("Refresh Catalog Now") {
                        model.syncCatalog()
                    }
                    .disabled(model.busy)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Catalog Updates")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Display & Hardware Tab

    @ViewBuilder
    private var displayTab: some View {
        @Bindable var bindableModel = model
        Form {
            Section {
                Toggle("Start VMs in full screen", isOn: $bindableModel.fullscreen)
                Text("Automatically expand virtual machine windows to fill the screen on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Default Graphics Adapter", selection: $bindableModel.gpu) {
                    Text("VirtIO GPU (Hardware Accelerated)").tag("virtio")
                    Text("RAM Framebuffer (ramfb fallback)").tag("ramfb")
                }
                Text("VirtIO GPU is recommended for modern operating systems. Use RAM Framebuffer for early bootloaders or older OSes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Display & Window")
            }

            Section {
                TextField("Default RAM", text: $bindableModel.mem, prompt: Text(defaultMem))
                presetRow(title: "RAM presets", options: ["1G", "2G", "4G", "8G", "16G"]) {
                    model.mem = $0
                }

                TextField("Default CPUs", text: $bindableModel.cpus, prompt: Text(String(defaultCPUs)))
                presetRow(title: "CPU presets", options: ["1", "2", "4", "8"]) {
                    model.cpus = $0
                }

                TextField("Default Disk Size", text: $bindableModel.diskSize, prompt: Text(defaultDiskSize))
                presetRow(title: "Disk presets", options: ["10G", "20G", "40G", "80G"]) {
                    model.diskSize = $0
                }

                TextField("Default SSH Port", text: $bindableModel.sshPort, prompt: Text("None"))
                Text("Host port forwarded to guest port 22. Leave blank to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hardware Defaults")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - QEMU & Advanced Tab

    @ViewBuilder
    private var advancedTab: some View {
        @Bindable var bindableModel = model
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra QEMU Flags")
                        .font(.headline)
                    Text("Additional arguments appended to the QEMU binary execution command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("e.g. -cpu host -device usb-mouse -snapshot", text: $bindableModel.extraQemuFlags, axis: .vertical)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...5)
                        .textFieldStyle(.roundedBorder)

                    Text("Separate arguments by spaces. Quotation marks (' or \") can be used for arguments containing spaces.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("QEMU Arguments")
            }

            Section {
                Picker("Default Architecture", selection: $bindableModel.arch) {
                    Text("ARM64 (Apple Silicon)").tag("arm64")
                    Text("x86_64 / AMD64 (Intel)").tag("amd64")
                }
                Text("Fallback architecture used when an image's architecture cannot be detected automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Default Firmware", selection: $bindableModel.firmware) {
                    Text("Automatic").tag("auto")
                    Text("UEFI (EDK2)").tag("uefi")
                    Text("Legacy BIOS (x86)").tag("bios")
                }

                Picker("Default x86 Hardware", selection: $bindableModel.hw) {
                    Text("Automatic").tag("auto")
                    Text("Standard (q35, AHCI, e1000)").tag("standard")
                    Text("Legacy PC (i440fx, IDE, PCnet)").tag("legacy")
                    Text("virtio").tag("virtio")
                }
                Text("Automatic uses Legacy PC for images that only boot with BIOS, such as DOS, Windows 9x and XP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Architecture & Firmware")
            }

            Section {
                LabeledContent("Host Architecture", value: hostArch())
                LabeledContent("Hypervisor Acceleration", value: "Apple Hypervisor Framework (HVF)")
                if let armPath = model.detectedQemuArmPath {
                    LabeledContent("QEMU ARM64", value: armPath)
                } else {
                    LabeledContent("QEMU ARM64", value: "Not found")
                }
                if let x86Path = model.detectedQemuX86Path {
                    LabeledContent("QEMU x86_64", value: x86Path)
                } else {
                    LabeledContent("QEMU x86_64", value: "Not found")
                }
                if let imgPath = model.detectedQemuImgPath {
                    LabeledContent("qemu-img", value: imgPath)
                } else {
                    LabeledContent("qemu-img", value: "Not found")
                }
            } header: {
                Text("System Diagnostics")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func presetRow(title: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { opt in
                    Button(opt) {
                        onSelect(opt)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }
}
