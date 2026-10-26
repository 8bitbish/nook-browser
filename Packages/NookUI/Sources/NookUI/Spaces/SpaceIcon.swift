// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceIcon.swift
//  Nook
//
//  A space's icon the way Arc shows it, beside the space's name and in the bottom bar: the emoji
//  the Arc import brought over, or an SF Symbol name. Nil when the space has neither, so callers
//  can fall back to the accent dot.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import NookDesign
import NookTabsCore

public struct SpaceIcon: View {
    let space: SpaceRecord
    let font: Font

    public init(space: SpaceRecord, font: Font) {
        self.space = space
        self.font = font
    }

    /// Whether `space` has something to draw.
    public static func exists(for space: SpaceRecord) -> Bool {
        space.isAgent || kind(of: space.icon) != nil
    }

    public var body: some View {
        if space.isAgent {
            Image(systemName: "sparkles")
                .font(font.weight(.semibold))
                .foregroundStyle(NookDesign.Surface.agentGradient)
        } else {
            switch Self.kind(of: space.icon) {
            case .emoji(let text)?:
                // Its own width, always: an emoji is wider than its point size, and a Text offered
                // less (the 16pt favicon column) cuts the glyph off.
                Text(text).font(font).fixedSize()
            case .symbol(let name)?:
                Image(systemName: name).font(font)
            case nil:
                EmptyView()
            }
        }
    }

    private enum Kind {
        case emoji(String)
        case symbol(String)
    }

    private static func kind(of icon: String) -> Kind? {
        let trimmed = icon.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // One grapheme with an emoji presentation: what Arc stores for a space.
        if trimmed.count == 1, let scalar = trimmed.unicodeScalars.first,
           scalar.properties.isEmojiPresentation || trimmed.unicodeScalars.count > 1 {
            return .emoji(trimmed)
        }
        #if canImport(AppKit)
        let isSymbol = NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil
        #else
        let isSymbol = UIImage(systemName: trimmed) != nil
        #endif
        if isSymbol { return .symbol(trimmed) }
        return nil
    }
}
