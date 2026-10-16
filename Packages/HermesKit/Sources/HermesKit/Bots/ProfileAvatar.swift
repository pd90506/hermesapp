import Foundation

/// A profile's avatar as Hermes stores it: an image in the profile's asset store
/// (`profiles.get_asset` / `profiles.set_asset`, `tui_gateway/methods_profiles.py:411-463`),
/// sent as a data URL. Hermes Desktop's Bots plugin uses the same asset, so an
/// avatar set in either app shows in both.
public enum ProfileAvatar {
    /// What `profiles.set_asset` accepts (`methods_profiles.py:432-433`).
    public static let maxBytes = 2_000_000

    /// The image bytes of a `data:<mime>;base64,…` URL (or bare base64).
    public static func decode(dataURL: String) -> Data? {
        let payload: Substring
        if dataURL.hasPrefix("data:") {
            guard let comma = dataURL.firstIndex(of: ","),
                dataURL[..<comma].hasSuffix(";base64")
            else { return nil }
            payload = dataURL[dataURL.index(after: comma)...]
        } else {
            payload = Substring(dataURL)
        }
        guard let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters),
            !data.isEmpty
        else { return nil }
        return data
    }

    /// `image` as a data URL, its type sniffed from the first bytes (PNG when unknown;
    /// the server sniffs it again and refuses anything else).
    public static func dataURL(_ image: Data) -> String {
        "data:\(mimeType(of: image));base64,\(image.base64EncodedString())"
    }

    static func mimeType(of image: Data) -> String {
        let bytes = [UInt8](image.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/png"
    }
}

extension Bot {
    /// The profile has an avatar image on the server.
    public var hasAvatar: Bool { profile.hasAvatar == true }

    /// The avatar colour picked in Hermes Desktop (`ui_meta['hermes-bots'].color`,
    /// `plugins/hermes-bots/data.ts:189-191`) as 0xRRGGBB, when it is a hex colour.
    public var avatarColor: UInt32? {
        guard var hex = profile.uiMeta?["hermes-bots"]?["color"]?.stringValue?.trimmed, hex.hasPrefix("#") else {
            return nil
        }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return value
    }
}
