import Foundation
import HermesProtocol

/// Hermes' reasoning-effort words, mirroring `apps/shared/src/reasoning-effort.ts`
/// (itself a mirror of the backend's `VALID_REASONING_EFFORTS`).
public enum ReasoningEffort {
    /// The levels, ascending. `none` is not a level: it is thinking turned off.
    public static let levels = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    public static let off = "none"
    /// What Hermes uses when nothing is configured (`reasoning-effort.ts:13-15`,
    /// `methods_config.py:214,222`).
    public static let defaultLevel = "medium"

    /// The choices to offer for a model, in menu order. Empty when the model
    /// has no reasoning control, so the picker hides
    /// (`apps/desktop/src/app/chat/composer/reasoning-pill.tsx:43-45`). `none`
    /// comes first unless the model cannot turn thinking off
    /// (`app/shell/model-edit-submenu.tsx:134`). An unknown model keeps the
    /// dial: the catalog itself defaults `reasoning` to true (`inventory.py:317-321`).
    public static func choices(for capabilities: ModelCapabilities?) -> [String] {
        if capabilities?.reasoning == false { return [] }
        let canDisable = capabilities?.canDisableReasoning != false
        return (canDisable ? [off] : []) + levels
    }

    /// Whether `config.set reasoning` may be sent this value: `none` or a level,
    /// exactly as written. Display words (`on`, `off`, `show`, `hide`, `full`,
    /// `clamp`, …) would rewrite global display config instead
    /// (`methods_config_set.py:312-317`).
    public static func isSendable(_ value: String) -> Bool {
        value == off || levels.contains(value)
    }

    /// Normalises a reported value (`" High "` → `high`); `nil` for blanks.
    public static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        return value
    }

    /// Menu and pill copy, from Desktop's `i18n/en.ts` `modelOptions`.
    public static func label(_ value: String) -> String {
        switch value.lowercased() {
        case "none": "Off"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra High"
        case "max": "Max"
        case "ultra": "Ultra"
        default: value
        }
    }
}
