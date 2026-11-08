import AppKit
import CrabKit
import SwiftUI
import Virtualization

/// The guest's display. Attached as soon as the virtual machine exists so the
/// screen is connected before `start`, including underneath the install overlay.
struct MacScreen: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
    }
}

struct MacOSGuestScreen: View {
    let guest: MacOSGuest
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if guest.showsDisplay, let vm = guest.virtualMachine {
                MacScreen(virtualMachine: vm)
            }
            if guest.phase != .running {
                VStack(spacing: 14) {
                    Text(title)
                        .font(.title2.bold())
                    if guest.phase == .installing, let fraction = guest.installFraction {
                        ProgressView(value: fraction)
                            .frame(width: 280)
                        Text("\(Int(fraction * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if guest.phase == .preparing || guest.phase == .starting || guest.phase == .installing {
                        ProgressView()
                    }
                    Text(guest.message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if !guest.notes.isEmpty && (guest.phase == .preparing || guest.phase == .installing) {
                        Text(guest.notes.joined(separator: "\n"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if guest.phase == .failed || guest.phase == .stopped {
                        Button("Close", action: onClose)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(maxWidth: 460)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if guest.phase == .running {
                HStack(spacing: 12) {
                    Button("Shut Down") { guest.requestStop() }
                    Button("Force Off", role: .destructive) {
                        Task { await guest.forceStop() }
                    }
                    Spacer()
                    Text(guest.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private var title: String {
        switch guest.phase {
        case .preparing: "Preparing"
        case .installing: "Installing macOS"
        case .starting: "Starting"
        case .running: guest.displayName
        case .stopped: "Stopped"
        case .failed: "Couldn't start"
        }
    }
}

@MainActor
final class MacOSGuestWindowController: NSWindowController, NSWindowDelegate {
    let guest: MacOSGuest
    var suppressClose = false
    var onUserClose: () -> Void

    init(guest: MacOSGuest, onUserClose: @escaping () -> Void) {
        self.guest = guest
        self.onUserClose = onUserClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = guest.displayName
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MacOSGuestScreen(guest: guest, onClose: { [weak self] in self?.onUserClose() })
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        if suppressClose { return }
        onUserClose()
    }
}
