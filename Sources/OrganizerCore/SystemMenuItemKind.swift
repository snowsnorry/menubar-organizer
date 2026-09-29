import Foundation

/// Presentation only. Classification never grants control of a system item.
public enum SystemMenuItemKind: String, CaseIterable, Sendable {
    case timeMachine, inputSource, clock, controlCenter, battery, wifi, bluetooth
    case sound, focus, spotlight, siri, weather, screenMirroring, displays
    case nowPlaying, accessibility, userSwitcher, keyboardBrightness, vpn

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
        case .vpn: "network"
        }
    }

    /// Presentation symbols for read-only modules whose localized AX titles
    /// may change or disappear while the menu bar is collapsed.
    public static func symbol(forPositionID id: String) -> String? {
        switch id {
        case "system-position:module:AudioVideoModule": "video.badge.waveform"
        case "system-position:module:AirDrop": "dot.radiowaves.left.and.right"
        case "system-position:module:UserSwitcher": "person.crop.circle"
        default: nil
        }
    }

    /// Match only known AX identifiers to a single position-table module.
    /// A display name may identify an icon without identifying its table key.
    public static func modulePositionKeys(metadata: [String]) -> Set<String> {
        let modules: [String: String] = [
            "FocusModes": "module:FocusModes",
            "com.apple.menuextra.focusmode": "module:FocusModes",
            "com.apple.menuextra.audiovideo": "module:AudioVideoModule",
            "com.apple.menuextra.airdrop": "module:AirDrop",
            "com.apple.menuextra.user": "module:UserSwitcher",
            "Battery": "module:Battery",
            "Bluetooth": "module:Bluetooth", "Clock": "module:Clock",
            "Displays": "module:Displays", "KeyboardBrightness": "module:KeyboardBrightness",
            "com.apple.controlcenter.KeyboardBrightness": "module:KeyboardBrightness",
            "Sound": "module:Sound", "WiFi": "module:WiFi",
            "com.apple.controlcenter.WiFi": "module:WiFi",
            "com.apple.menuextra.wifi": "module:WiFi",
            "ScreenMirroring": "module:ScreenMirroring", "BentoBox": "module:BentoBox-0"
        ]
        return Set(metadata.compactMap { modules[$0] })
    }

    /// A SystemUIServer process may host several legacy extras. Match each
    /// child against its own metadata and the configured bundle, never its index.
    public static func legacyPositionKey(metadata: [String], configuredExtras: [String]) -> String? {
        let configured = Set(configuredExtras.map { URL(fileURLWithPath: $0).lastPathComponent })
        let candidates: [(menu: String, identifier: String, markers: Set<String>)] = [
            ("TimeMachine.menu", "com.apple.menuextra.TimeMachine",
             ["com.apple.menuextra.TimeMachine", "TimeMachine.menu", "TimeMachineMenuExtra.TMMenuExtraHost", "Time Machine"]),
            ("VPN.menu", "com.apple.menuextra.vpn",
             ["com.apple.menuextra.vpn", "VPN.menu", "VPN"])
        ]
        let matches = candidates.filter { candidate in
            configured.contains(candidate.menu) && metadata.contains { value in
                if candidate.markers.contains(value) { return true }
                let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
                return candidate.menu == "TimeMachine.menu"
                    ? normalized.contains("timemachine")
                    : normalized == "vpn" || normalized == "comapplemenuextravpn"
            }
        }
        guard matches.count == 1 else { return nil }
        return "status:com.apple.systemuiserver::\(matches[0].identifier)"
    }

    /// Resolve an unlabelled legacy extra only when the complete owner inventory
    /// leaves exactly one configured extra and exactly one empty AX child.
    /// A changing generic title such as "System Menu" is never an identity.
    public static func legacyPositionKeys(metadataByChild: [[String]],
                                          configuredExtras: [String]) -> [String?] {
        var keys = metadataByChild.map {
            legacyPositionKey(metadata: $0, configuredExtras: configuredExtras)
        }
        let configured = Set(configuredExtras.map { URL(fileURLWithPath: $0).lastPathComponent })
        let known: [String: String] = [
            "TimeMachine.menu": "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine",
            "VPN.menu": "status:com.apple.systemuiserver::com.apple.menuextra.vpn"
        ]
        let unmatched = configured.compactMap { known[$0] }.filter { !keys.contains($0) }
        let empty = metadataByChild.indices.filter { metadataByChild[$0].isEmpty && keys[$0] == nil }
        guard configured.allSatisfy({ known[$0] != nil }), unmatched.count == 1,
              empty.count == 1 else { return keys }
        keys[empty[0]] = unmatched[0]
        return keys
    }

    /// The Control Center host also owns unrelated status items, so its bundle
    /// identifier alone is not evidence that a child is the pinned control.
    public static func isControlCenterStatusItem(metadata: [String]) -> Bool {
        let identifiers: Set<String> = [
            "BentoBox", "BentoBox-0", "PrimaryBento", "com.apple.controlcenter.BentoBox",
            "com.apple.controlcenter.PrimaryBento",
            "com.apple.menuextra.controlcenter", "Control Center", "Пункт управления"
        ]
        return metadata.contains { identifiers.contains($0) }
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
            (.vpn, ["vpn", "comapplemenuextravpn"]),
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
