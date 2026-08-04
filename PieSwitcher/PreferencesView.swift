import SwiftUI

/// The Preferences window's top-level tabs. Each tab carries an SF Symbol shown
/// above its label in the icon toolbar.
///
/// The tabs are cut along the **stage of a summon** — open the wheel, decide
/// what is in it, pick from it, decide how it looks — not along the object being
/// configured. Every setting in this app is about the wheel, so a tab named for
/// the wheel would cover everything and separate nothing; the stage is what
/// actually tells the user which tab to open. It is also what keeps the two
/// keyboard panes apart: Activation → Keyboard is the key that summons,
/// Selection → Keyboard is the keys that navigate an open wheel.
///
/// Positions is the one tab outside that arc, and deliberately so: its position
/// shortcuts (Bringr-dk3) skip every stage at once — no summon, no hover, no
/// pick — so filing them under any single stage would misdescribe them. They act
/// on the wheel the other tabs configure without ever showing it. It is named for
/// what it binds, not for the fact that it binds keys: "Shortcuts" would read as
/// the home of every shortcut in the app, and the key that summons the wheel lives
/// under Activation while the keys that drive it live under Selection.
///
/// The selected tab is persisted under `defaultsKey` so the window reopens where
/// the user left it, and the menu bar's "About PieSwitcher" item writes
/// `PreferencesTab.about.rawValue` into that key before opening the window so it
/// lands on the About tab.
enum PreferencesTab: String, CaseIterable {
    case general
    case activation
    case positions
    case contents
    case selection
    case appearance
    case about

    static let defaultsKey = "preferences.selectedTab"
    static let `default`: PreferencesTab = .general

    var title: String {
        switch self {
        case .general: return "General"
        case .activation: return "Activation"
        case .positions: return "Positions"
        case .contents: return "Contents"
        case .selection: return "Selection"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .activation: return "cursorarrow.click.2"
        case .positions: return "list.number"
        case .contents: return "list.bullet.rectangle"
        case .selection: return "hand.point.up.left"
        case .appearance: return "paintbrush"
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
                case .positions: PositionShortcutsTab()
                case .contents: ContentsTab()
                case .selection: SelectionTab()
                case .appearance: AppearanceSettings()
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

// MARK: - Contents

/// Sub-tab selector for the Contents tab — everything that decides what the
/// wheel lists. "Apps" is the curated pinned list and the show-other-running-apps
/// toggle; "Hidden" is the ignore list; "Sorting" is the ordering rules; "Scope"
/// is the screen/space/minimized/hidden filters that decide which apps and
/// windows the wheel can even see.
///
/// "Hidden" — not "Excluded" — because Activation owns a pane named "Excluded
/// Apps" that suppresses the wheel's *activation*. Two panes named the same
/// thing read as one setting, so a user who wants the wheel to stay shut inside
/// Blender types the bundle id here and gets a list filter instead.
enum ContentsSubTab: String, PreferencesSubTab {
    case apps
    case hidden
    case sorting
    case scope

    static let defaultsKey = "preferences.contentsSubTab"
    static let `default`: ContentsSubTab = .apps

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .hidden: return "Hidden"
        case .sorting: return "Sorting"
        case .scope: return "Scope"
        }
    }
}

private struct ContentsTab: View {
    @AppStorage(ContentsSubTab.defaultsKey)
    private var subTabRaw = ContentsSubTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { ContentsSubTab(rawValue: subTabRaw) ?? .default },
            set: { subTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesSubTabs(selection: selection)

            switch selection.wrappedValue {
            case .apps: MyAppsPane()
            case .hidden: HiddenAppsPane()
            case .sorting: SortingSettings()
            case .scope: CollectionSettings()
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

/// The "Hidden" pane: thin wrapper that drops `HiddenAppsEditor` into the
/// standard `PreferencesPane` Form so the section styling matches the rest of
/// the window. The footer names the other pane outright, because this one
/// filters the wheel's contents and Activation → Excluded Apps stops the wheel
/// from opening — the two are easy to reach for interchangeably.
private struct HiddenAppsPane: View {
    var body: some View {
        PreferencesPane {
            Section {
                HiddenAppsEditor()
            } header: {
                Text("Hidden apps")
            } footer: {
                Text("Apps listed here never appear in the wheel, even if they have open "
                     + "windows.\n\n"
                     + "This only filters what the wheel shows — a hidden app can still "
                     + "summon it. To stop the wheel from opening at all while an app is "
                     + "active, add it under Activation → Excluded Apps.")
            }
        }
    }
}

// MARK: - Selection

/// Sub-tab selector for the Selection tab — everything that happens once the
/// wheel is already open, from moving between slices to what the desktop looks
/// like after a commit. "Keyboard" is arrow/number navigation, "Trackpad" the
/// hover haptics, "Dwell" the rest-to-commit timer, "Windows" what happens to
/// the windows themselves as you hover and once you pick.
///
/// Its Keyboard pane and Activation's are distinct: this one is the keys that
/// drive an open wheel, Activation's is the key that opens it.
enum SelectionSubTab: String, PreferencesSubTab {
    case keyboard
    case trackpad
    case dwell
    case windows

    static let defaultsKey = "preferences.selectionSubTab"
    static let `default`: SelectionSubTab = .keyboard

    var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .trackpad: return "Trackpad"
        case .dwell: return "Dwell"
        case .windows: return "Windows"
        }
    }
}

private struct SelectionTab: View {
    @AppStorage(SelectionSubTab.defaultsKey)
    private var subTabRaw = SelectionSubTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { SelectionSubTab(rawValue: subTabRaw) ?? .default },
            set: { subTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesSubTabs(selection: selection)

            switch selection.wrappedValue {
            case .keyboard: KeyboardNavigationSettings()
            case .trackpad: TrackpadHapticsSettings()
            case .dwell: DwellActivationSettings()
            case .windows: RevealSettings()
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
