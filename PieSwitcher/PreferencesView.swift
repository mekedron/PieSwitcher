import SwiftUI

/// The Preferences window's top-level tabs after the Bringr-93j.106 redesign. The
/// 8 narrow tabs in Bringr-93j.97 were regrouped into 6 broader ones; tabs heavy
/// enough to need it get a sub-tab strip (Activation, Wheel, Apps, Controls).
/// Each tab carries an SF Symbol shown above its label in the icon toolbar.
///
/// The selected tab is persisted under `defaultsKey` so the window reopens where
/// the user left it, and the menu bar's "About PieSwitcher" item writes
/// `PreferencesTab.about.rawValue` into that key before opening the window so it
/// lands on the About tab.
enum PreferencesTab: String, CaseIterable {
    case general
    case activation
    case wheel
    case apps
    case controls
    case about

    static let defaultsKey = "preferences.selectedTab"
    static let `default`: PreferencesTab = .general

    var title: String {
        switch self {
        case .general: return "General"
        case .activation: return "Activation"
        case .wheel: return "Wheel"
        case .apps: return "Apps"
        case .controls: return "Controls"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .activation: return "cursorarrow.click.2"
        case .wheel: return "circle.dashed.inset.filled"
        case .apps: return "square.grid.3x3.fill"
        case .controls: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

/// The Preferences window root. The window is split into three vertical zones:
///
/// 1. The Logic-Pro-style icon toolbar (`PreferencesToolbar`) at the top.
/// 2. An optional segmented sub-tab strip when the current top-level tab has
///    sub-sections.
/// 3. The selected pane's `Form` content, scrollable as needed.
///
/// The width is fixed (820 pt) so the icon toolbar always fits all six tabs at
/// once with comfortable spacing; the height settles around 620 pt which
/// matches the previous tabbed layout.
struct PreferencesView: View {
    @AppStorage(PreferencesTab.defaultsKey)
    private var selectedTabRaw = PreferencesTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { PreferencesTab(rawValue: selectedTabRaw) ?? .default },
            set: { selectedTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesToolbar(selection: selection)

            Group {
                switch selection.wrappedValue {
                case .general: GeneralTab()
                case .activation: ActivationTab()
                case .wheel: WheelTab()
                case .apps: AppsTab()
                case .controls: ControlsTab()
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 820, height: 620)
    }
}

// MARK: - General

/// General: permissions and launch-at-login. The bootstrap stuff a first-time
/// user hits, so it leads the tab order and has no sub-tabs.
private struct GeneralTab: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager

    var body: some View {
        PreferencesPane {
            Section("Permissions") {
                permissionRow
            }

            Section {
                Toggle(
                    "Launch PieSwitcher at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
            } header: {
                Text("Startup")
            } footer: {
                Text("PieSwitcher starts automatically when you log in and runs in the menu bar.")
            }
        }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: permissions.status.symbolName)
                    .font(.title3)
                    .foregroundStyle(permissions.isTrusted ? Color.green : Color.orange)
                Text(permissions.status.title)
                    .font(.headline)
                Spacer()
            }

            Text(permissions.status.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if !permissions.isTrusted {
                    Button("Open System Settings") {
                        permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Re-check") {
                    permissions.recheck()
                }
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Activation

/// Sub-tab selector for the Activation tab (Mouse / Keyboard). Each input source
/// has its own pane because the mouse pane is large (methods, timing, lock
/// semantics) and bundling them would push the Activation tab past the form
/// budget. Mirrors Logic Pro's sub-tab strip pattern.
enum ActivationSubTab: String, PreferencesSubTab {
    case mouse
    case keyboard
    case exclusions

    static let defaultsKey = "preferences.activationSubTab"
    static let `default`: ActivationSubTab = .mouse

    var title: String {
        switch self {
        case .mouse: return "Mouse"
        case .keyboard: return "Keyboard"
        case .exclusions: return "Excluded Apps"
        }
    }
}

private struct ActivationTab: View {
    @AppStorage(ActivationSubTab.defaultsKey)
    private var subTabRaw = ActivationSubTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { ActivationSubTab(rawValue: subTabRaw) ?? .default },
            set: { subTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesSubTabs(selection: selection)

            switch selection.wrappedValue {
            case .mouse: MouseActivationSettings()
            case .keyboard: KeyboardActivationSettings()
            case .exclusions: ActivationExclusionSettings()
            }
        }
    }
}

// MARK: - Wheel

/// Sub-tab selector for the Wheel tab (Behavior / Appearance). Behaviour is the
/// reveal strategy + hide-on-commit; Appearance is everything visual (size,
/// opacity, glass). Both pull from the same wheel domain so they share a tab,
/// but the two sets of controls are unrelated to each other so they get
/// separate panes.
enum WheelSubTab: String, PreferencesSubTab {
    case behavior
    case appearance

    static let defaultsKey = "preferences.wheelSubTab"
    static let `default`: WheelSubTab = .behavior

    var title: String {
        switch self {
        case .behavior: return "Behavior"
        case .appearance: return "Appearance"
        }
    }
}

private struct WheelTab: View {
    @AppStorage(WheelSubTab.defaultsKey)
    private var subTabRaw = WheelSubTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { WheelSubTab(rawValue: subTabRaw) ?? .default },
            set: { subTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesSubTabs(selection: selection)

            switch selection.wrappedValue {
            case .behavior: RevealSettings()
            case .appearance: AppearanceSettings()
            }
        }
    }
}

// MARK: - Apps

/// Sub-tab selector for the Apps tab. "My Apps" is the curated pinned list and
/// the show-other-running-apps toggle; "Excluded" is the ignore list; "Sorting"
/// is the ordering rules; "Collection" is the screen/space/minimized/hidden
/// filters that decide which apps and windows the wheel can even see. Putting
/// these four under one top-level tab keeps the toolbar lean (vs. the
/// Bringr-93j.97 design where each was its own tab).
enum AppsSubTab: String, PreferencesSubTab {
    case pinned
    case excluded
    case sorting
    case collection

    static let defaultsKey = "preferences.appsSubTab"
    static let `default`: AppsSubTab = .pinned

    var title: String {
        switch self {
        case .pinned: return "My Apps"
        case .excluded: return "Excluded"
        case .sorting: return "Sorting"
        case .collection: return "Collection"
        }
    }
}

private struct AppsTab: View {
    @AppStorage(AppsSubTab.defaultsKey)
    private var subTabRaw = AppsSubTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { AppsSubTab(rawValue: subTabRaw) ?? .default },
            set: { subTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesSubTabs(selection: selection)

            switch selection.wrappedValue {
            case .pinned: MyAppsPane()
            case .excluded: ExcludedAppsPane()
            case .sorting: SortingSettings()
            case .collection: CollectionSettings()
            }
        }
    }
}

/// The "My Apps" pane: the curated app list, plus the "Show all other running
/// apps" toggle that decides whether non-pinned running apps trail the pinned
/// ones. Pulled out as its own view so the section structure inside `AppsTab`
/// stays a thin switch.
private struct MyAppsPane: View {
    @AppStorage(CuratedApps.showOtherRunningAppsDefaultsKey)
    private var showsOtherRunningApps = CuratedApps.showOtherRunningAppsDefault

    var body: some View {
        PreferencesPane {
            Section {
                MyAppsEditor()
            } header: {
                Text("Pinned apps")
            } footer: {
                Text("Pinned apps lead the wheel in this order. Drag app bundles from "
                     + "Finder or the Dock onto the list, or use the + button.")
            }

            Section {
                Toggle("Show all other running apps", isOn: $showsOtherRunningApps)
            } header: {
                Text("Other apps")
            } footer: {
                Text("When on, every other app with a window on the current screen follows "
                     + "your pinned apps. When off, the wheel shows only your pinned apps.")
            }
        }
    }
}

/// The "Excluded" pane: thin wrapper that drops the existing
/// `IgnoreListSettings` into the standard `PreferencesPane` Form so the section
/// styling matches the rest of the window.
private struct ExcludedAppsPane: View {
    var body: some View {
        PreferencesPane {
            Section {
                IgnoreListSettings()
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("Apps listed here never appear in the wheel, even if they have open "
                     + "windows. Separate entries with commas — each a bundle identifier "
                     + "(com.apple.Safari) or an app name (Safari).")
            }
        }
    }
}

// MARK: - Controls

/// Sub-tab selector for the Controls tab (Keyboard / Trackpad / Dwell).
/// "Controls" is everything that happens once the wheel is already open —
/// distinct from Activation, which is about getting the wheel up in the first
/// place. Bundles the keyboard navigation, trackpad haptics, and dwell-to-
/// commit timer under one top-level tab.
enum ControlsSubTab: String, PreferencesSubTab {
    case keyboard
    case trackpad
    case dwell

    static let defaultsKey = "preferences.controlsSubTab"
    static let `default`: ControlsSubTab = .keyboard

    var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .trackpad: return "Trackpad"
        case .dwell: return "Dwell"
        }
    }
}

private struct ControlsTab: View {
    @AppStorage(ControlsSubTab.defaultsKey)
    private var subTabRaw = ControlsSubTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { ControlsSubTab(rawValue: subTabRaw) ?? .default },
            set: { subTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesSubTabs(selection: selection)

            switch selection.wrappedValue {
            case .keyboard: KeyboardNavigationSettings()
            case .trackpad: TrackpadHapticsSettings()
            case .dwell: DwellActivationSettings()
            }
        }
    }
}

// MARK: - About

/// About: app info, repo link, "Check for Updates…". Bringr-93j.97 folded the
/// former standalone About window into Preferences as a tab; the menu bar's
/// "About PieSwitcher" item writes `PreferencesTab.about` into UserDefaults
/// before opening the window so it lands here.
private struct AboutTab: View {
    var body: some View {
        ScrollView {
            AboutView()
                .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    PreferencesView()
        .environmentObject(PermissionsManager(probe: { false }))
        .environmentObject(LaunchAtLoginManager(probe: { false }))
}
