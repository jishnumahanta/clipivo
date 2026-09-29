import AppKit
import SwiftUI
import ClipivoCore

/// Hosts SwiftUI content in an ordinary titled window (Settings, Welcome).
@MainActor
final class HostedWindowController<Content: View>: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let size: NSSize
    private let resizable: Bool
    private let content: () -> Content

    init(title: String, size: NSSize, resizable: Bool = true, content: @escaping () -> Content) {
        self.title = title
        self.size = size
        self.resizable = resizable
        self.content = content
    }

    func show() {
        if window == nil {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            if resizable { style.insert(.resizable) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content())
            window.toolbarStyle = .unified
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Release the SwiftUI tree so settings state does not linger in memory.
        window?.contentView = nil
        window = nil
    }
}

struct WelcomeView: View {
    let app: AppModel
    let onDone: () -> Void
    @State private var axGranted = AccessibilityPermission.isGranted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to \(Branding.productName)").font(.title2.weight(.semibold))
                    Text(Branding.tagline).foregroundStyle(.secondary)
                }
            }
            step(1, "Copy as usual", "Everything you copy — text, images, links, files — is kept on this Mac, forever by default.")
            step(2, "Press \(app.preferences.panelHotKey?.displayString ?? "your shortcut") anywhere", "Search your history, then press Return to paste into the app you were using.")
            VStack(alignment: .leading, spacing: 6) {
                step(3, "Allow automatic paste", "macOS asks for Accessibility access so \(Branding.productName) can send ⌘V for you. Without it, clips are copied and you press ⌘V yourself.")
                HStack {
                    if axGranted {
                        Label("Accessibility access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Accessibility Access…") {
                            AccessibilityPermission.requestPrompt()
                            AccessibilityPermission.openSystemSettings()
                        }
                    }
                }
                .padding(.leading, 34)
            }
            Toggle("Launch \(Branding.productName) at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in try? LaunchAtLogin.set(value) }
                .padding(.leading, 34)
            Label("Private by design: no account, no cloud, no analytics. Password managers are ignored and secrets are detected locally.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Get Started", action: onDone).keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(26)
        .frame(width: 520)
        .onReceive(timer) { _ in axGranted = AccessibilityPermission.isGranted }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
