import AppKit
import SwiftUI
import TilerCore

/// Content of the settings window (SPEC §5): the preset library in a sidebar on the left, the
/// Palette pane on the right — 11 × 6 wells, the settings controls and a live preview. Every
/// change goes straight into `store.config`, which saves and notifies immediately.
struct EditorView: View {
    @Bindable var store: ConfigStore
    let loginItem: LoginItem

    @Environment(\.colorScheme) private var colorScheme

    enum Layout {
        /// Unified-toolbar titlebar height; the traffic lights sit centered in it.
        static let titlebarHeight: CGFloat = 52
        static let sidebarInset: CGFloat = 8
        static let sidebarWidth: CGFloat = 236
        static let sidebarCornerRadius: CGFloat = 18
        static let paneInset: CGFloat = 32
        /// Tall enough to show the live preview at a decent size without pushing the window past
        /// ninja's visible frame (856 pt, SPEC §0): 300 pt (width-bound, 78 %) made the window
        /// 918 pt tall, 62 pt past the Dock. Clamped back so the whole window fits.
        static let previewHeight: CGFloat = 210
        /// Fixed window content size; everything is laid out to fit it without clipping. Kept
        /// comfortably under ninja's 856 pt visibleFrame (SPEC §0) including the titlebar.
        static let windowSize = CGSize(
            width: sidebarInset + sidebarWidth + 2 * paneInset + Well.gridSize.width,
            height: 830)
    }

    var body: some View {
        let theme = EditorTheme(colorScheme)
        HStack(alignment: .top, spacing: 0) {
            LibrarySidebar(palette: store.config.palette)
                .frame(width: Layout.sidebarWidth)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Layout.sidebarCornerRadius, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: Layout.sidebarCornerRadius, style: .continuous)
                        .fill(theme.sidebarBackground.swiftUI)
                        .shadow(color: theme.sidebarShadow.swiftUI, radius: 5, x: 0, y: 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: Layout.sidebarCornerRadius, style: .continuous)
                                .strokeBorder(theme.sidebarEdge.swiftUI, lineWidth: 1)
                        }
                }
                .padding([.leading, .top, .bottom], Layout.sidebarInset)
            PalettePane(store: store, loginItem: loginItem)
                .padding(.horizontal, Layout.paneInset)
        }
        .frame(width: Layout.windowSize.width, height: Layout.windowSize.height, alignment: .topLeading)
        .background(theme.paneBackground.swiftUI)
        .ignoresSafeArea()
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginItem.refresh()
        }
    }
}

// MARK: Library

/// The two width variants of every preset (SPEC §1 "Width variants"): `<id>` and `<id>-sm`.
enum WidthVariant: String, CaseIterable, Identifiable {
    case fullWidth
    case stageManager

    var id: Self { self }

    var title: String {
        switch self {
        case .fullWidth: "Full width"
        case .stageManager: "Stage Manager"
        }
    }

    /// Library presets of this variant, split like the library's sections.
    var presets: (moveResize: [Preset], arrange: [Preset]) {
        switch self {
        case .fullWidth: (PresetLibrary.moveResize, PresetLibrary.arrange)
        case .stageManager: (PresetLibrary.moveResizeStageManager, PresetLibrary.arrangeStageManager)
        }
    }
}

/// Every preset (icon + name) of the chosen width variant, grouped "Move & Resize" /
/// "Arrange". Rows are drag sources; a check mark shows which presets already sit in a well.
private struct LibrarySidebar: View {
    let palette: PaletteLayout

    @State private var variant = WidthVariant.fullWidth

    var body: some View {
        let presets = variant.presets
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights (the sidebar starts `sidebarInset` below the top).
            Color.clear.frame(height: EditorView.Layout.titlebarHeight - EditorView.Layout.sidebarInset)
            Picker("Width", selection: $variant) {
                ForEach(WidthVariant.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .help("Stage Manager presets leave the Stage Manager strip on the left free.")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Move & Resize", presets.moveResize)
                    section("Arrange", presets.arrange)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private func section(_ title: String, _ presets: [Preset]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22, alignment: .center)
            ForEach(presets) { preset in
                LibraryRow(preset: preset, placed: palette.position(of: preset.id) != nil)
            }
        }
    }
}

private struct LibraryRow: View {
    let preset: Preset
    let placed: Bool

    /// The name without the variant suffix; the segmented switch already says which variant.
    private var shortName: String {
        preset.isStageManagerVariant && preset.name.hasSuffix(Preset.stageManagerNameSuffix)
            ? String(preset.name.dropLast(Preset.stageManagerNameSuffix.count))
            : preset.name
    }

    var body: some View {
        HStack(spacing: 9) {
            PresetIconView(preset: preset, size: Well.iconSize)
            Text(shortName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if placed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("In the palette")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
        .overlay {
            LibraryDragSource(
                presetID: preset.id,
                toolTip: placed ? "\(preset.name) is in the palette" : "Drag into a well to add \(preset.name)")
        }
    }
}

// MARK: Palette pane

private struct PalettePane: View {
    @Bindable var store: ConfigStore
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Palette").font(.system(size: 15, weight: .semibold))
                Text("Drag presets from the library into the wells. Drag out or right-click to remove.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(height: EditorView.Layout.titlebarHeight)

            WellGrid(layout: store.config.palette) { store.config.palette = $0 }
                .frame(width: Well.gridSize.width, height: Well.gridSize.height)
                .padding(.top, 10)

            SettingsForm(store: store, loginItem: loginItem)
                .padding(.top, 18)
            Divider().padding(.top, 14).padding(.bottom, 10)
            PalettePreviewBox(
                layout: store.config.palette,
                paletteSize: store.config.settings.paletteSize,
                box: CGSize(width: Well.gridSize.width, height: EditorView.Layout.previewHeight))
            Spacer(minLength: 0)
        }
        .frame(width: Well.gridSize.width)
    }
}

/// The settings below the wells (SPEC §5), bound to `TilerSettings`: palette size, palette
/// hotkey, Stage Manager inset, launch at login, and the opt-in green-button hover trigger with
/// its dependent controls indented and enabled only while it is on. No gap controls (windows
/// always touch) and no Stage Manager toggle (every preset has a Stage Manager variant).
private struct SettingsForm: View {
    @Bindable var store: ConfigStore
    let loginItem: LoginItem

    static let sliderWidth: CGFloat = 200

    var body: some View {
        let settings = store.config.settings
        let inset = clamped(\.stageManagerInset, TilerSettings.stageManagerInsetRange)
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Palette size:")
                    HStack(spacing: 10) {
                        Slider(value: snapped(\.paletteSize, step: 0.05), in: TilerSettings.paletteSizeRange)
                            .frame(width: Self.sliderWidth)
                            .accessibilityLabel("Palette size")
                        Text("\(Int((settings.paletteSize * 100).rounded())) %")
                            .monospacedDigit()
                    }
                }
                GridRow {
                    label("Palette hotkey:")
                    HotkeyRecorder(hotkey: $store.config.settings.paletteHotkey,
                                   caption: "Or click the Tiler icon in the menu bar.")
                }
                GridRow {
                    label("Stage Manager inset:")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            TextField("Stage Manager inset", value: inset, format: .number.precision(.fractionLength(0)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 46)
                                .accessibilityLabel("Stage Manager inset")
                            Stepper("Stage Manager inset", value: inset, in: TilerSettings.stageManagerInsetRange, step: 4)
                                .labelsHidden()
                            Text("pt")
                        }
                        Text("Kept free on the left by the “Stage Manager” presets.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    label("Startup:")
                    VStack(alignment: .leading, spacing: 3) {
                        // Truth lives only in SMAppService.mainApp.status (the real login-item
                        // registration), read through `loginItem.isOn`. `TilerSettings
                        // .launchAtLogin` is deliberately NOT written here any more: nothing in
                        // the app ever reads that config key (confirmed by grep), so writing it
                        // only faked persistence — hand-editing or restoring config.json never
                        // actually changed whether Tiler launches at login. The field stays in
                        // the JSON schema for decode compatibility with old config files; it is
                        // unused dead data and the UI must not pretend otherwise.
                        Toggle("Launch at login", isOn: Binding(
                            get: { loginItem.isOn },
                            set: { on in loginItem.setOn(on) }))
                        if let note = loginItem.note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(note)
                        }
                    }
                }
            }
            hoverTrigger
        }
        .font(.system(size: 13))
    }

    /// The opt-in hover trigger (SPEC §4.C) and, indented, what only applies to it.
    private var hoverTrigger: some View {
        let settings = store.config.settings
        // Disabled controls dim themselves; plain text has to be dimmed by hand.
        let text: HierarchicalShapeStyle = settings.hoverTriggerEnabled ? .primary : .tertiary
        let caption: HierarchicalShapeStyle = settings.hoverTriggerEnabled ? .secondary : .tertiary
        return VStack(alignment: .leading, spacing: 7) {
            Toggle("Also show palette when hovering the green button (beta)",
                   isOn: $store.config.settings.hoverTriggerEnabled)
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Show macOS menu by default (⌘ for Tiler)",
                           isOn: $store.config.settings.showMacOSMenuByDefault)
                    Text(settings.showMacOSMenuByDefault
                         ? "Hold ⌘ while hovering for the Tiler palette."
                         : "Hold ⌘ while hovering for the macOS menu.")
                        .font(.system(size: 11))
                        .foregroundStyle(caption)
                        .padding(.leading, 20)
                }
                HStack(spacing: 10) {
                    Text("Delay")
                        .foregroundStyle(text)
                    Slider(value: snapped(\.hoverDelay, step: 0.05), in: TilerSettings.hoverDelayRange)
                        .frame(width: Self.sliderWidth)
                        .accessibilityLabel("Hover delay")
                    Text("\(settings.hoverDelay.formatted(.number.precision(.fractionLength(2)))) s")
                        .monospacedDigit()
                        .foregroundStyle(text)
                }
            }
            .padding(.leading, 20)
            .disabled(!settings.hoverTriggerEnabled)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).gridColumnAlignment(.trailing)
    }

    /// A binding that rounds slider values to `step`.
    private func snapped(_ key: WritableKeyPath<TilerSettings, Double>, step: Double) -> Binding<Double> {
        Binding(
            get: { store.config.settings[keyPath: key] },
            set: { store.config.settings[keyPath: key] = ($0 / step).rounded() * step })
    }

    /// A binding that clamps to `range` (typed values in text fields can exceed it).
    private func clamped(_ key: WritableKeyPath<TilerSettings, Double>,
                         _ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { store.config.settings[keyPath: key] },
            set: { store.config.settings[keyPath: key] = min(max($0.rounded(), range.lowerBound), range.upperBound) })
    }
}
