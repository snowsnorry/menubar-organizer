import Foundation

/// Presentation only. Classification never grants control of a system item.
public enum SystemMenuItemKind: String, CaseIterable, Sendable {
    case timeMachine, inputSource, clock, controlCenter, battery, wifi, bluetooth
    case sound, focus, spotlight, siri, weather, screenMirroring, displays
    case nowPlaying, accessibility, userSwitcher, keyboardBrightness

    public var localizationKey: String { "system.\(rawValue)" }

    public var symbol: String {
        switch self {
        case .timeMachine: "clock.arrow.circlepath"
        case .inputSource: "character.bubble"
        case .clock: "clock"
        case .controlCenter: "switch.2"
        case .battery: "battery.100percent"
        case .wifi: "wifi"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .sound: "speaker.wave.2"
        case .focus: "moon"
        case .spotlight: "magnifyingglass"
        case .siri: "sparkles"
        case .weather: "cloud.sun"
        case .screenMirroring: "rectangle.on.rectangle"
        case .displays: "display"
        case .nowPlaying: "play.circle"
        case .accessibility: "accessibility"
        case .userSwitcher: "person.crop.circle"
        case .keyboardBrightness: "keyboard"
        }
    }

    /// Match only known AX identifiers to a single position-table module.
    /// A display name may identify an icon without identifying its table key.
    public static func modulePositionKeys(metadata: [String]) -> Set<String> {
        let modules: [String: String] = [
            "FocusModes": "module:FocusModes", "Battery": "module:Battery",
            "Bluetooth": "module:Bluetooth", "Clock": "module:Clock",
            "Displays": "module:Displays", "KeyboardBrightness": "module:KeyboardBrightness",
            "Sound": "module:Sound", "WiFi": "module:WiFi",
            "com.apple.controlcenter.WiFi": "module:WiFi",
            "com.apple.menuextra.wifi": "module:WiFi",
            "ScreenMirroring": "module:ScreenMirroring", "BentoBox": "module:BentoBox-0"
        ]
        return Set(metadata.compactMap { modules[$0] })
    }

    public static func identify(bundleID: String, metadata: [String]) -> Self? {
        guard bundleID.hasPrefix("com.apple.") else { return nil }
        switch bundleID {
        case "com.apple.TextInputMenuAgent": return .inputSource
        case "com.apple.weather.menu": return .weather
        case "com.apple.campo": return .spotlight
        default: break
        }
        func normalized(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let values = metadata.map(normalized)
        let aliases: [(Self, [String])] = [
            (.timeMachine, ["timemachine"]),
            (.inputSource, ["inputsource", "inputmenu", "textinput", "сменаязыка", "источникиввода"]),
            (.controlCenter, ["bentobox", "primarybento", "пунктуправления"]),
            (.screenMirroring, ["screenmirroring", "повторэкрана"]),
            (.keyboardBrightness, ["keyboardbrightness", "яркостьклавиатуры"]),
            (.nowPlaying, ["nowplaying", "исполняется"]),
            (.userSwitcher, ["userswitcher", "fastuserswitching", "сменапользователя"]),
            (.accessibility, ["accessibility", "универсальныйдоступ"]),
            (.battery, ["battery", "аккумулятор"]), (.wifi, ["wifi"]),
            (.bluetooth, ["bluetooth"]), (.sound, ["volume", "sound", "звук"]),
            (.focus, ["focus", "donotdisturb", "фокусирование"]),
            (.spotlight, ["spotlight"]), (.siri, ["siri"]),
            (.weather, ["weather", "погода"]), (.clock, ["clock", "часы"]),
            (.displays, ["displays", "дисплеи"])
        ]
        // Per-icon metadata takes priority over the shared host bundle name.
        for value in values {
            if let match = aliases.first(where: { $0.1.contains(where: value.contains) }) { return match.0 }
        }
        if values.contains(where: { $0.contains("controlcenter") }) { return .controlCenter }
        let bundle = normalized(bundleID)
        if bundle == "comapplecontrolcenter" { return .controlCenter }
        for (kind, tokens) in aliases where tokens.contains(where: bundle.contains) {
            return kind
        }
        return nil
    }
}
