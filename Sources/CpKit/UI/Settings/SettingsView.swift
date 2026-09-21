import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings: two tabs, one line per setting, no prose.
///
/// The first build explained each option in a paragraph under it, which is how
/// a settings screen ends up longer than the app. If a row needs explaining,
/// the row is wrong.
public struct SettingsView: View {

    public enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case privacy = "Privacy"
        public var id: String { rawValue }
    }

    @Bindable private var settings: Settings
    private let controller: AppController
    private let clipboardAccess: () -> ClipboardAccess?

    @State private var tab: Tab = .general
    @State private var canPaste = false
    @State private var historySummary = "…"
    @State private var showingIgnoredApps = false
    @State private var confirmingClear = false

    public init(
        settings: Settings,
        controller: AppController,
        tab: Tab = .general,
        clipboardAccess: @escaping () -> ClipboardAccess? = { ClipboardAccess.current() }
    ) {
        self._settings = Bindable(settings)
        self.controller = controller
        self.clipboardAccess = clipboardAccess
        self._tab = State(initialValue: tab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabs
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case .general: general
                    case .privacy: privacy
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: Theme.Metric.settingsWidth, height: Theme.Metric.settingsHeight)
        .background(Theme.windowBackground)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showingIgnoredApps) {
            IgnoredAppsSheet(settings: settings) { showingIgnoredApps = false }
        }
        .alert("Clear history?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { controller.clearHistory() }
        } message: {
            Text("Everything except pinned clips will be forgotten.")
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                let isOn = tab == item
                Button { tab = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isOn ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(isOn ? Theme.hover : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
        }
        .padding(.top, 34)
        .padding(.bottom, 6)
    }

    // MARK: - General

    private var general: some View {
        Group {
            SettingCard {
                SettingRow("Open cp") {
                    ShortcutRecorder(combo: settings.hotKey, failed: controller.lastError != nil) { combo in
                        settings.hotKey = combo
                        controller.registerHotKey()
                    }
                }
                SettingRow("Hold the shortcut to switch") {
                    Toggle("", isOn: $settings.holdToSwitch).toggleStyle(.switch).labelsHidden()
                }
                SettingRow("After choosing") {
                    Picker("", selection: $settings.pasteAutomatically) {
                        Text("Paste into the app").tag(true)
                        Text("Copy only").tag(false)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                SettingRow("Paste rich text", isLast: true) {
                    Picker("", selection: $settings.pasteRichAsPlain) {
                        Text("With formatting").tag(false)
                        Text("As plain text").tag(true)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }

            SettingCard {
                SettingRow("Keep") {
                    Picker("", selection: $settings.historyLimit) {
                        Text("500 clips").tag(500)
                        Text("2,000 clips").tag(2_000)
                        Text("10,000 clips").tag(10_000)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                SettingRow("Search text in images") {
                    Toggle("", isOn: $settings.recognizeText).toggleStyle(.switch).labelsHidden()
                }
                SettingRow("Show page titles for links", isLast: true) {
                    Toggle("", isOn: $settings.resolveLinkTitles).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingCard {
                SettingRow("Paste into other apps", isLast: clipboardAccess() == nil) {
                    if canPaste {
                        HStack(spacing: 5) {
                            Text("Allowed").foregroundStyle(Theme.positive)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.positive)
                        }
                    } else {
                        Button("Allow…") {
                            controller.requestPastePermission()
                            Self.openPrivacyPane("Privacy_Accessibility")
                        }
                    }
                }
                if let access = clipboardAccess() {
                    SettingRow("Read the clipboard", isLast: true) {
                        HStack(spacing: 8) {
                            Text(access.label)
                                .foregroundStyle(access == .allowed ? Theme.positive : Theme.ink2)
                            if access != .allowed {
                                Button("Open Settings…") { Self.openPrivacyPane(nil) }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacy: some View {
        Group {
            SettingCard {
                SettingRow("Passwords") {
                    Picker("", selection: $settings.secretLifetime) {
                        Text("Forget after 30 seconds").tag(TimeInterval(30))
                        Text("Forget after 1 minute").tag(TimeInterval(60))
                        Text("Forget after 5 minutes").tag(TimeInterval(300))
                        Text("Don't keep").tag(TimeInterval(0))
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                SettingRow("Ignore these apps", isLast: true) {
                    Button {
                        showingIgnoredApps = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(settings.ignoredBundleIDs.count) apps")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.ink2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            SettingCard {
                SettingRow("History") {
                    Text(historySummary)
                }
                SettingDangerRow("Clear history…") { confirmingClear = true }
            }
        }
    }

    // MARK: - Refreshing

    /// Permission and history size are facts about the machine, not settings:
    /// they are re-read whenever the window comes forward.
    private func refresh() async {
        canPaste = controller.canPaste
        historySummary = await controller.historySummary()
    }

    static func openPrivacyPane(_ anchor: String?) {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        let url = URL(string: anchor.map { "\(base)?\($0)" } ?? base)
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The apps cp never records from, with the ability to add and remove them.
struct IgnoredAppsSheet: View {

    @Bindable var settings: Settings
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ignore these apps")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(settings.ignoredBundleIDs).sorted(), id: \.self) { bundleID in
                        HStack(spacing: 9) {
                            if let icon = AppIconProvider.shared.icon(forBundleID: bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            }
                            Text(Self.name(for: bundleID))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button {
                                settings.ignoredBundleIDs.remove(bundleID)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 260)

            HStack {
                CapsuleButton("Add app…") { add() }
                Spacer(minLength: 8)
                CapsuleButton("Done", prominent: true) { done() }
            }
            .padding(14)
        }
        .frame(width: 380)
        .background(Theme.windowBackground)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.ignoredBundleIDs.insert(bundleID)
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}
