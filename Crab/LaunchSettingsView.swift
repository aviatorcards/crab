import CrabKit
import SwiftUI

/// The settings every boot from the app uses, like the CLI's flags.
struct LaunchSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Mode", selection: $model.launchMode) {
                    ForEach(ImageLaunchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .help("Choose whether to discard, save, or run without disk")
                if model.launchMode == .keep {
                    TextField("Save as", text: $model.namedVMInput, prompt: Text("Named after the image"))
                }
            } header: {
                Text("Boot Mode")
            } footer: {
                Text(model.launchMode.footerDescription)
            }

            Section("Hardware") {
                TextField("RAM", text: $model.mem, prompt: Text(defaultMem))
                TextField("CPUs", text: $model.cpus, prompt: Text(String(defaultCPUs)))
                TextField("New disk", text: $model.diskSize, prompt: Text(defaultDiskSize))
                TextField("SSH port", text: $model.sshPort, prompt: Text("Pick one"))
                    .help("Forward localhost:PORT to the guest's SSH; blank picks a free port for new VMs")
            }

            Section("Firmware & Display") {
                Picker("Architecture", selection: $model.arch) {
                    Text("arm64").tag("arm64")
                    Text("amd64").tag("amd64")
                }
                .help("Used when an image's architecture can't be detected")
                Picker("Firmware", selection: $model.firmware) {
                    Text("Auto").tag("auto")
                    Text("UEFI").tag("uefi")
                    Text("BIOS").tag("bios")
                }
                Picker("x86 hardware", selection: $model.hw) {
                    Text("Auto").tag("auto")
                    Text("Standard").tag("standard")
                    Text("Legacy PC").tag("legacy")
                    Text("virtio").tag("virtio")
                }
                .help("New x86 VMs: Standard is q35 with AHCI and e1000; Legacy PC is i440fx with IDE and PCnet, for DOS, Windows 9x/XP and other older OSes. Auto picks Legacy PC for images that only boot with BIOS")
                Picker("Graphics", selection: $model.gpu) {
                    Text("virtio-gpu").tag("virtio")
                    Text("ramfb").tag("ramfb")
                }
                .help("arm64: ramfb is a plain framebuffer, for OSes that only draw to the boot framebuffer (-r)")
                Toggle("Full screen", isOn: $model.fullscreen)
            }
        }
        .formStyle(.grouped)
    }
}
