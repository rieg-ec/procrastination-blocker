import AppKit
import ProcrastinationBlockerCore
import SwiftUI

@MainActor
final class WebsiteSettingsWindowController: NSWindowController {
    init(store: WebsiteStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Blocked Websites"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: WebsiteSettingsView(store: store) { [weak self] in
                self?.close()
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        window?.center()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct WebsiteSettingsView: View {
    @ObservedObject var store: WebsiteStore
    let onDone: () -> Void

    @State private var input = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Blocked Websites")
                    .font(.title2.weight(.semibold))
                Text("These domains are snapshotted when a focus session starts. Exact domains and their www versions are blocked.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("reddit.com", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.domains, id: \.self) { domain in
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .foregroundStyle(.secondary)
                            Text(domain.value)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                remove(domain)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(domain.value)")
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 42)

                        if domain != store.domains.last {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            HStack {
                Button("Reset Defaults") {
                    store.resetDefaults()
                    errorMessage = nil
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 470, minHeight: 430)
    }

    private func addDomain() {
        do {
            try store.add(input)
            input = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ domain: BlockedDomain) {
        do {
            try store.remove(domain)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
