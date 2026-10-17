import AppKit
import HermesKit
import SwiftUI
import Testing

/// The Appearance text sizes, as the renderer and the UI fonts use them.
@MainActor
@Suite struct AppearanceTests {
    /// Untouched settings: 14 pt UI and content, 12 pt code; the UI styles scale up from
    /// the system's 13 pt.
    @Test func defaultsAreFourteenAndTwelve() {
        let sizes = TextSizes(AppearanceSettings())
        #expect(sizes == TextSizes(ui: 14, content: 14, code: 12))
        #expect(sizes.uiScale == 14.0 / 13)
        #expect(sizes.uiBodyFont != nil)
        #expect(TextSizes.pointSize(.callout) == NSFont.preferredFont(forTextStyle: .callout).pointSize)
    }

    /// At the system's size the UI keeps the system styles untouched.
    @Test func systemSizeKeepsTheSystemStyles() {
        let sizes = TextSizes(ui: 13, content: 13, code: 12)
        #expect(sizes.uiScale == 1)
        #expect(sizes.uiBodyFont == nil)
    }

    @Test func customSizesResolve() {
        var settings = AppearanceSettings()
        settings.setSize(.ui, 16, default: 14)
        settings.setSize(.content, 15, default: 14)
        settings.setSize(.code, 14, default: 12)
        let sizes = TextSizes(settings)
        #expect(sizes == TextSizes(ui: 16, content: 15, code: 14))
        #expect(sizes.uiScale == 16.0 / 13)
        #expect(sizes.uiBodyFont != nil)
    }

    /// Prose at the content size, a code block nested in a list at the code size.
    @Test func rendererUsesTheContentAndCodeSizes() throws {
        let selection = MarkdownSelection(parsing: "Body text\n\n- item\n\n  ```\n  nested code\n  ```")
        let text = MarkdownNativeText.make(selection, bodySize: 15, codeSize: 14).text
        func font(_ needle: String) throws -> NSFont {
            let index = (text.string as NSString).range(of: needle).location
            #expect(index != NSNotFound, "\(needle) not rendered")
            return try #require(text.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        }
        #expect(try font("Body").pointSize == 15)
        #expect(try font("nested").pointSize == 14)
    }

    /// Without a code size, code keeps callout's ratio to the body, as before.
    @Test func rendererWithoutACodeSizeKeepsTheCalloutRatio() throws {
        let selection = MarkdownSelection(parsing: "- item\n\n  ```\n  nested code\n  ```")
        let text = MarkdownNativeText.make(selection, bodySize: 13).text
        let index = (text.string as NSString).range(of: "nested").location
        let font = try #require(text.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == NSFont.preferredFont(forTextStyle: .callout).pointSize)
    }
}
