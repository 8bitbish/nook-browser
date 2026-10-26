// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarHeader.swift
//  Nook
//
//  Created by Aether on 15/11/2025.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

/// Header section of the sidebar: the URL bar, and with the sidebar on the right the sidebar and
/// AI toggles above it. On the left those share the traffic-light row with back, forward and
/// reload, as in Arc. The space name is not up here: each space page carries its own heading.
struct SidebarHeader: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) var nookSettings
    let isSidebarHovered: Bool

    var body: some View {
        VStack(spacing: NookDesign.Spacing.sectionGap) {
            if nookSettings.sidebarPosition != .left {
                windowControls
            }

            if !nookSettings.topBarAddressView {
                urlBar
            }
        }
    }

    private var windowControls: some View {
        HStack(spacing: 0) {
            SidebarToggleButtons()
            Spacer(minLength: 0)
        }
        .frame(height: NookDesign.Size.chromeControl)
        .environmentObject(browserManager)
        .environment(windowState)
        .padding(.horizontal, NookDesign.Spacing.sidebarInset)
    }

    private var urlBar: some View {
        URLBarView(isSidebarHovered: isSidebarHovered)
            .padding(.horizontal, NookDesign.Spacing.sidebarInset)
    }
}

// MARK: - Sidebar Toggles
/// The sidebar and AI toggles. In a narrow sidebar the AI toggle gives way first, so back,
/// forward and reload keep their place beside it.
struct SidebarToggleButtons: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) var nookSettings

    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons(includingAI: nookSettings.showAIAssistant)
            buttons(includingAI: false)
        }
    }

    private func buttons(includingAI: Bool) -> some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            Button("Toggle Sidebar", systemImage: nookSettings.sidebarPosition == .left ? "sidebar.left" : "sidebar.right") {
                browserManager.toggleSidebar(for: windowState)
            }

            if includingAI {
                Button("Toggle AI Assistant", systemImage: "sparkle") {
                    browserManager.toggleAISidebar(for: windowState)
                }
            }
        }
        .nookIconButtons()
        .fixedSize()
    }
}
