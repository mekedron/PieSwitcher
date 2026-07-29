import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Layout primitives for the redesigned Preferences window (Bringr-93j.106). The new
/// design swaps the macOS-26 title-bar `TabView` for a Logic Pro-style icon toolbar
/// at the top, optional segmented sub-tabs below it, and `Form` / `Section` /
/// `LabeledContent` for every settings pane so labels right-align in a fixed column
/// and inputs start at the same x-position across every screen.

/// A single icon-over-label tab button used by `PreferencesToolbar`. The selected
/// state gets a soft accent-tinted backdrop; hover lights the row up subtly so the
/// click target is obvious.
private struct PreferencesToolbarItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(height: 26)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(width: 76, height: 54)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
    }
}

/// Horizontal toolbar of icon-over-label buttons at the top of the Preferences window
/// (Bringr-93j.106). Replaces the macOS-26 title-bar `TabView` so the tabs are visible
/// at any window width and the icons make the row scannable, matching Logic Pro's
/// Preferences toolbar.
struct PreferencesToolbar: View {
    @Binding var selection: PreferencesTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(PreferencesTab.allCases, id: \.self) { tab in
                    PreferencesToolbarItem(
                        title: tab.title,
                        systemImage: tab.symbolName,
                        isSelected: selection == tab
                    ) {
                        selection = tab
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()
        }
    }
}

/// A protocol the sub-tab enums (e.g. `ActivationSubTab`) conform to so the
/// segmented sub-tab strip can be generic over them. Each sub-tab carries a
/// display title; SF Symbols are optional and not used in v1 of the strip (Logic
/// Pro's sub-tabs are plain text under the toolbar).
protocol PreferencesSubTab: Hashable, CaseIterable, RawRepresentable where RawValue == String {
    var title: String { get }
}

/// The segmented sub-tab strip shown under the toolbar inside tabs that have
/// distinct sub-sections (Activation, Wheel, Apps, Controls). Mirrors Logic Pro's
/// "General / Tracks / Mixer / Editors" strip — a thin horizontal bar of titles
/// with the selected one accented. Backed by SwiftUI's `.segmented` Picker style
/// so the look matches native macOS.
struct PreferencesSubTabs<Tab: PreferencesSubTab>: View where Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab

    var body: some View {
        HStack {
            Picker("", selection: $selection) {
                ForEach(Array(Tab.allCases), id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// The standard Preferences pane: a `Form` with `.grouped` styling, padded so it
/// breathes inside the window. Every tab body composes its sections inside this
/// wrapper so spacing, padding, and form rendering stay consistent across the
/// window.
struct PreferencesPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// A leading-aligned paragraph for explanatory text that doesn't fit a single
/// section footer — typically the "About mouse activation" preamble or a closing
/// reminder. Sits inside a `Section` so it inherits the form's card backdrop and
/// horizontal alignment.
struct PreferencesParagraph: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - App list editors

/// Shared chrome for the three app-list editors — My Apps, Hidden, Excluded. They present
/// the same interaction (a bordered list, a `+` that picks an app, a `−` that removes the
/// selected one), so they draw from one set of pieces here rather than three near-identical
/// copies that drift apart a row height and a glyph size at a time.

/// Fixed size of the `+` / `−` glyphs under a list. Pinning the *label* is what makes the
/// two controls the same width: a bordered button sizes itself to whatever it wraps, so a
/// bare "plus" and a bare "minus" come out visibly different widths.
private enum AppListControlMetrics {
    static let glyphWidth: CGFloat = 22
    static let glyphHeight: CGFloat = 15
    static let spacing: CGFloat = 6
}

private extension View {
    func appListControlGlyph() -> some View {
        frame(width: AppListControlMetrics.glyphWidth, height: AppListControlMetrics.glyphHeight)
    }
}

/// The `+` that opens a picker menu. `.menuIndicator(.hidden)` drops the disclosure
/// chevron, which otherwise sits flush against the plus and reads as one broken two-glyph
/// smudge rather than a button; the menu still opens on a plain click.
struct AppListAddMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "plus").appListControlGlyph()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

/// The `+` that runs a single action, for a list whose only add path is the Open panel.
struct AppListAddButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").appListControlGlyph()
        }
        .help(help)
    }
}

/// The control bar under a list: the caller's add control, then a matching remove button.
/// `.bordered` is applied to the bar rather than inside each control so the add button, the
/// add menu, and the minus all render as the same chip.
struct AppListControls<Add: View>: View {
    let removeHelp: String
    let isRemoveEnabled: Bool
    let onRemove: () -> Void
    @ViewBuilder let add: () -> Add

    var body: some View {
        HStack(spacing: AppListControlMetrics.spacing) {
            add()

            Button(action: onRemove) {
                Image(systemName: "minus").appListControlGlyph()
            }
            .disabled(!isRemoveEnabled)
            .help(removeHelp)

            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// One row: Finder icon, display name, and an optional second line carrying the value
/// actually stored. That second line is what lets the user tell an entry that matched by
/// bundle id from one that matched by app name without reading the defaults; it is dropped
/// when it only repeats the title.
struct AppListRow: View {
    let icon: NSImage
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .lineLimit(1)
                if let subtitle, subtitle.caseInsensitiveCompare(title) != .orderedSame {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension View {
    /// The shared look of an editor's list: bordered alternating rows, a fixed height, and
    /// an accent ring while a Finder or Dock drag hovers it.
    func appListBox(height: CGFloat, isDropTargeted: Bool) -> some View {
        listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: height)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0)
            }
    }

    /// Centred placeholder shown over an empty list, so a fresh pane explains itself
    /// instead of presenting a blank box.
    func appListEmptyState(_ message: String, isVisible: Bool) -> some View {
        overlay {
            if isVisible {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }
}

/// One running app offered by an editor's quick-add menu.
struct RunningAppCandidate: Identifiable {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage

    var id: String { bundleIdentifier }

    var curated: CuratedApp { CuratedApp(bundleIdentifier: bundleIdentifier, name: name) }

    /// Currently-running ordinary (Dock) apps, sorted by display name — the ones that can
    /// own focus or reach the wheel, so the ones worth listing. PieSwitcher itself and apps
    /// with no bundle id are skipped; several instances of one bundle id collapse to a
    /// single entry. Picking the app you are already in is the shortest path to listing it,
    /// and the only practical one for apps installed outside /Applications (a Steam or
    /// launcher library, where the Open panel turns into a hunt).
    static func current() -> [RunningAppCandidate] {
        let selfID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppCandidate? in
                guard let id = app.bundleIdentifier, id != selfID, seen.insert(id).inserted else {
                    return nil
                }
                return RunningAppCandidate(
                    bundleIdentifier: id,
                    name: app.localizedName ?? id,
                    icon: app.icon ?? NSWorkspace.shared.icon(for: .application)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The Open panel every editor uses to pick app bundles. Scoped to applications and opened
/// at /Applications; returns the picked URLs, or nothing when the user cancels.
enum AppBundlePanel {
    static func pick(prompt: String, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = prompt
        panel.message = message
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

/// A short label + value slider row that fits cleanly into a `Form`. The label
/// sits in the form's right-aligned column; the slider, the numeric field, and
/// the unit suffix share the second column. Mirrors `MouseActivationSettings`'
/// original ad-hoc HStack layout but plugs into `LabeledContent` so every slider
/// across the Preferences window aligns the same way.
struct PreferencesSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var fractionDigits: Int = 0

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range)
                TextField(
                    "",
                    value: $value,
                    format: .number.precision(.fractionLength(fractionDigits))
                )
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
            }
        }
    }
}
