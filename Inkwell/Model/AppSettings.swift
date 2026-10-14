import SwiftUI
import PencilKit

// MARK: - Themes

struct InkTheme: Equatable {
    var accent: Color
    var background: Color
    var surface: Color
    var sidebar: Color
}

enum ThemeID: String, CaseIterable, Identifiable {
    case vermilion, marine, moss, plum, graphite

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var theme: InkTheme {
        switch self {
        case .vermilion:
            return InkTheme(accent: Color(light: 0xC93D22, dark: 0xFF7A59),
                            background: Color(light: 0xF5EFE3, dark: 0x171619),
                            surface: Color(light: 0xFFFCF5, dark: 0x232227),
                            sidebar: Color(light: 0xECE4D3, dark: 0x1D1C20))
        case .marine:
            return InkTheme(accent: Color(light: 0x1D5BBF, dark: 0x66A6FF),
                            background: Color(light: 0xEDF1F5, dark: 0x0F141B),
                            surface: Color(light: 0xFAFCFF, dark: 0x19202A),
                            sidebar: Color(light: 0xE0E7EF, dark: 0x141A22))
        case .moss:
            return InkTheme(accent: Color(light: 0x2E7A4C, dark: 0x62D08E),
                            background: Color(light: 0xEFF1E7, dark: 0x111612),
                            surface: Color(light: 0xFBFCF6, dark: 0x1B221D),
                            sidebar: Color(light: 0xE2E6D6, dark: 0x161C18))
        case .plum:
            return InkTheme(accent: Color(light: 0x8A3F7A, dark: 0xE08FD0),
                            background: Color(light: 0xF3EBF0, dark: 0x181118),
                            surface: Color(light: 0xFFFAFD, dark: 0x251B25),
                            sidebar: Color(light: 0xE8DCE4, dark: 0x1E151E))
        case .graphite:
            return InkTheme(accent: Color(light: 0x2B2B2B, dark: 0xEDEDED),
                            background: Color(light: 0xF2F2EF, dark: 0x111111),
                            surface: Color(light: 0xFFFFFF, dark: 0x1D1D1D),
                            sidebar: Color(light: 0xE6E6E2, dark: 0x181818))
        }
    }
}

private struct InkThemeKey: EnvironmentKey {
    static let defaultValue = ThemeID.vermilion.theme
}

extension EnvironmentValues {
    var inkTheme: InkTheme {
        get { self[InkThemeKey.self] }
        set { self[InkThemeKey.self] = newValue }
    }
}

// MARK: - Settings

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PencilAction: String, CaseIterable, Identifiable {
    case quickPalette, toggleEraser, previousTool, undo, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quickPalette: return "Show quick palette"
        case .toggleEraser: return "Switch to eraser and back"
        case .previousTool: return "Switch to previous tool"
        case .undo: return "Undo"
        case .off: return "Do nothing"
        }
    }
}

@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var themeID: ThemeID { didSet { defaults.set(themeID.rawValue, forKey: "themeID") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var iCloudEnabled: Bool { didSet { defaults.set(iCloudEnabled, forKey: "iCloudEnabled") } }
    var squeezeAction: PencilAction { didSet { defaults.set(squeezeAction.rawValue, forKey: "squeezeAction") } }
    var doubleTapAction: PencilAction { didSet { defaults.set(doubleTapAction.rawValue, forKey: "doubleTapAction") } }
    var dockCollapsed: Bool { didSet { defaults.set(dockCollapsed, forKey: "dockCollapsed") } }
    var dockAtTop: Bool { didSet { defaults.set(dockAtTop, forKey: "dockAtTop") } }
    var drawWithFinger: Bool { didSet { defaults.set(drawWithFinger, forKey: "drawWithFinger") } }
    /// While writing with the Pencil, ignore resting palms and stray fingers.
    var palmRejection: Bool { didSet { defaults.set(palmRejection, forKey: "palmRejection") } }
    /// How eagerly finger contacts near the Pencil count as your hand.
    var palmSensitivity: PalmSensitivity { didSet { defaults.set(palmSensitivity.rawValue, forKey: "palmSensitivity") } }
    /// Left-handed layout: pen tray and page strip mirror so your hand doesn't cover them.
    var leftHanded: Bool { didSet { defaults.set(leftHanded, forKey: "leftHanded") } }

    /// With finger drawing off (the default on iPad), only the Pencil writes and palms never leave a mark.
    var drawingPolicy: PKCanvasViewDrawingPolicy {
        drawWithFinger ? .anyInput : .pencilOnly
    }

    var theme: InkTheme { themeID.theme }

    init() {
        let d = UserDefaults.standard
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        themeID = ThemeID(rawValue: d.string(forKey: "themeID") ?? "") ?? .vermilion
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        iCloudEnabled = d.bool(forKey: "iCloudEnabled")
        squeezeAction = PencilAction(rawValue: d.string(forKey: "squeezeAction") ?? "") ?? .quickPalette
        doubleTapAction = PencilAction(rawValue: d.string(forKey: "doubleTapAction") ?? "") ?? .toggleEraser
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        let fingerDefault = true
        #else
        let fingerDefault = false
        #endif
        dockCollapsed = d.bool(forKey: "dockCollapsed")
        dockAtTop = d.bool(forKey: "dockAtTop")
        drawWithFinger = d.object(forKey: "drawWithFinger") as? Bool ?? fingerDefault
        palmRejection = d.object(forKey: "palmRejection") as? Bool ?? true
        palmSensitivity = PalmSensitivity(rawValue: d.string(forKey: "palmSensitivity") ?? "") ?? .medium
        leftHanded = d.bool(forKey: "leftHanded")
    }

    /// The first time an Apple Pencil touches a page, stop fingers (and palms) from inking. Happens once; after that
    /// the finger-drawing switch stays wherever you put it.
    func pencilDetected() {
        guard !defaults.bool(forKey: "pencilOnlyAutoSet") else { return }
        defaults.set(true, forKey: "pencilOnlyAutoSet")
        if drawWithFinger { drawWithFinger = false }
    }
}
