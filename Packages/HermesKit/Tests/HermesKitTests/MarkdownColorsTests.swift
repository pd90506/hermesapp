import Foundation
import Testing
@testable import HermesKit

struct MarkdownColorsTests {
    @Test func hexRoundTrips() throws {
        let color = try #require(RGBAColor(hex: "#0053FD"))
        #expect(color == RGBAColor(red: 0, green: 0x53 / 255.0, blue: 0xFD / 255.0))
        #expect(color.hex == "#0053FD")
        #expect(RGBAColor(hex: "0053fd1a")?.hex == "#0053FD1A")
        #expect(RGBAColor(hex: "#12345") == nil)
        #expect(RGBAColor(hex: "+FFFFF") == nil)
        #expect(RGBAColor(hex: "#GGGGGG") == nil)
    }

    /// A picked colour is kept to 8 bits a channel, so it compares equal after a save.
    @Test func channelsAreRoundedAndClamped() {
        let color = RGBAColor(red: 0.50001, green: 2, blue: -1, alpha: .nan)
        #expect(color.red == 128 / 255.0)
        #expect(color.green == 1)
        #expect(color.blue == 0)
        #expect(color.alpha == 0)
    }

    @Test func startsOnTheDesktopDefaultTheme() {
        let colors = MarkdownColors()
        #expect(colors.preset == .nous)
        #expect(colors.color(.link, .light).hex == "#0053FD")
        #expect(colors.color(.link, .dark).hex == "#4A84FE")
        #expect(!colors.hasCustomColors)
    }

    @Test func everyPresetColoursEveryElementInBothModes() {
        for preset in MarkdownColors.Preset.allCases {
            let palette = MarkdownColors.palette(preset)
            for element in MarkdownColors.Element.allCases {
                _ = palette[element].light
                _ = palette[element].dark
            }
        }
    }

    /// Text colours stay readable: opaque enough to see on the window.
    @Test func textColoursAreVisible() {
        let text: [MarkdownColors.Element] = [.heading, .bold, .link, .inlineCode, .quoteText, .tableHeaderText]
        for preset in MarkdownColors.Preset.allCases {
            for element in text {
                for mode in MarkdownColors.Mode.allCases {
                    #expect(MarkdownColors.palette(preset)[element][mode].alpha >= 0.5, "\(preset) \(element) \(mode)")
                }
            }
        }
    }

    @Test func aChangedColourOverridesOnlyItsMode() throws {
        var colors = MarkdownColors()
        let red = try #require(RGBAColor(hex: "#FF0000"))
        colors.setColor(red, for: .quoteBar, .dark)
        #expect(colors.color(.quoteBar, .dark) == red)
        #expect(colors.color(.quoteBar, .light) == MarkdownColors.palette(.nous)[.quoteBar].light)
        #expect(colors.isCustom(.quoteBar))
        #expect(!colors.isCustom(.link))
        #expect(colors.hasCustomColors)
    }

    /// Back at the preset's colour, the element follows the preset again.
    @Test func settingThePresetsColourForgetsIt() throws {
        var colors = MarkdownColors()
        colors.setColor(try #require(RGBAColor(hex: "#FF0000")), for: .heading, .light)
        colors.setColor(MarkdownColors.palette(.nous)[.heading].light, for: .heading, .light)
        #expect(!colors.isCustom(.heading))
        #expect(colors == MarkdownColors())
    }

    @Test func resetAndChoosingAPresetForgetChanges() throws {
        var colors = MarkdownColors()
        let red = try #require(RGBAColor(hex: "#FF0000"))
        colors.setColor(red, for: .heading, .light)
        colors.setColor(red, for: .link, .dark)
        colors.resetColor(.heading)
        #expect(!colors.isCustom(.heading))
        #expect(colors.isCustom(.link))
        colors.choose(.solarized)
        #expect(colors.preset == .solarized)
        #expect(!colors.hasCustomColors)
        #expect(colors.color(.heading, .light) == MarkdownColors.palette(.solarized)[.heading].light)
    }

    @Test func roundTripsThroughJSON() throws {
        var colors = MarkdownColors(preset: .catppuccin)
        colors.setColor(try #require(RGBAColor(hex: "#12345678")), for: .tableStripe, .light)
        let data = try JSONEncoder().encode(colors)
        #expect(try JSONDecoder().decode(MarkdownColors.self, from: data) == colors)
    }

    /// Saved by another version: what this one doesn't know is dropped, not fatal.
    @Test func decodingToleratesUnknownValues() throws {
        let json = ##"{"preset":"neon","colors":{"link":{"light":"#FF0000","sepia":"#00FF00"},"glow":{"dark":"#FFFFFF"},"heading":{"dark":"blue"}}}"##
        let colors = try JSONDecoder().decode(MarkdownColors.self, from: Data(json.utf8))
        #expect(colors.preset == .nous)
        #expect(colors.color(.link, .light).hex == "#FF0000")
        #expect(!colors.isCustom(.heading))
        #expect(try JSONDecoder().decode(MarkdownColors.self, from: Data("{}".utf8)) == MarkdownColors())
    }
}
