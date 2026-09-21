import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings.
///
/// The privacy section is first on purpose: it is the part of a clipboard manager
/// people are right to be suspicious of, and burying it under "History" would be
/// the wrong signal.
public struct SettingsView: View {

    @Bindable private var settings: Settings
    private let controller: AppController

    public init(settings: Settings, controller: AppController) {
        self._settings = Bindable(settings)
        self.controller = controller
    }

    public var body: some View {
        TabView {
            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 400)
    }

    // MARK: - Privacy

    private var privacyTab: some View {
        Form {
            Section {
                LabeledContent("Never captured") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(settings.ignoredBundleIDs).sorted(), id: \.self) { bundleID in
                            HStack(spacing: 6) {
                                if let icon = AppIconProvider.shared.icon(forBundleID: bundleID) {
                                    Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                                }
                                Text(displayName(for: bundleID))
                                    .font(Theme.Font.rowBody)
                                Spacer()
                                Button {
                                    settings.ignoredBundleIDs.remove(bundleID)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add app…") { addIgnoredApp() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("Copies made in these apps are dropped before they reach the history. Password managers are added by default.")
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Clippings marked private by their source app — using the `org.nspasteboard.ConcealedType` convention — are held for this session only and never written to disk. They appear in the list as locked rows so you can see the rule working.")
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Concealed clippings")
            }

            Section {
                Toggle("Look up page titles for links", isOn: $settings.resolveLinkTitles)
                Text("Off by default. When on, a request is made only for the link you have selected, and only to the site itself — never to a third-party favicon service.")
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Network")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("History") {
                LabeledContent("Keep") {
                    Picker("", selection: $settings.historyLimit) {
                        Text("500").tag(500)
                        Text("2,000").tag(2_000)
                        Text("10,000").tag(10_000)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("Pinned clippings are never trimmed.")
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Paste automatically after choosing", isOn: $settings.pasteAutomatically)
                if !controller.hasAccessibilityPermission {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Needs Accessibility access.")
                            .font(Theme.Font.metadata)
                        Button("Grant…") { controller.requestAccessibilityPermission() }
                            .controlSize(.small)
                    }
                }
                Toggle("Switch to a grid when results are mostly images", isOn: $settings.adaptiveImageGrid)
            }

            Section("Shortcut") {
                LabeledContent("Open picker") {
                    Text("⇧⌘V").font(Theme.Font.rowBodyMono)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        settings.ignoredBundleIDs.insert(bundleID)
    }
}
