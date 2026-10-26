// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSwitcherTitle.swift
//  Nook
//
//  A space's name heading its sidebar page, between favorites and pinned tabs, as in Arc.
//  Clicking it lists every space.
//

import SwiftUI
import NookDesign
import NookTabsCore
import NookWeb
import NookUI

struct SpaceSwitcherTitle: View {
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) private var nookSettings
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var dragSession = NookDragSessionManager.shared
    @State private var isHovering = false

    let spaceID: UUID
    let onNewSpace: () -> Void

    private var currentSpace: SpaceRecord? {
        tabs.space(spaceID)
    }

    var body: some View {
        if let space = currentSpace {
            // Also the pin target for a space whose pinned section is empty.
            let pinned = Parent.pinned(spaceID: space.id)
            NookDropZoneHostView(zoneID: .target(pinned), manager: dragSession, onDrop: { itemID in
                tabs.pin(itemID, to: pinned)
            }) {
                if windowState.privateTree != nil {
                    label(space)
                } else {
                    Menu {
                        menuContent(current: space)
                    } label: {
                        label(space)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    // Width may shrink so a long name fades out at the sidebar's edge.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// How far the emoji box reaches past the favicon column on each side.
    private let iconOverhang = (NookDesign.Size.headingIconBox - NookDesign.Size.favicon) / 2

    private func label(_ space: SpaceRecord) -> some View {
        let isDropTarget = dragSession.isDragging && dragSession.activeZone == .target(.pinned(spaceID: space.id))
        // As in Arc: the space's icon in the favicon column, the name in the title column, dimmer
        // than the rows under it.
        let hasIcon = SpaceIcon.exists(for: space)
        let title = HStack(spacing: NookDesign.Spacing.rowIconGap - iconOverhang) {
            if hasIcon {
                // Wider than the favicon column so the emoji is never cut off; the overhang comes
                // out of the padding and the gap, so it stays centred on the column and the name
                // stays on the title column.
                SpaceIcon(space: space, font: NookDesign.Font.spaceHeadingIcon)
                    .frame(width: NookDesign.Size.headingIconBox)
            }
            Text(space.name)
                .foregroundStyle(.secondary)
                .font(NookDesign.Font.spaceHeading)
        }
            .lineLimit(1)
            .fixedSize()
        // A name too long for the sidebar fades out, the way a tab row's title does.
        return ViewThatFits(in: .horizontal) {
            title
            title
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .nookTrailingFade()
        }
        // Lined up with the favicons of the rows below it.
        .padding(.leading, NookDesign.Spacing.rowPadding - (hasIcon ? iconOverhang : 0))
        .padding(.trailing, NookDesign.Spacing.rowPadding)
        .frame(height: NookDesign.Size.row)
        .background(
            NookDesign.Radius.shape(NookDesign.Radius.row)
                .fill(isHovering || isDropTarget ? NookDesign.Surface.fill : Color.clear)
        )
        .contentShape(NookDesign.Radius.shape(NookDesign.Radius.row))
        .onHoverTracking { isHovering = $0 }
    }

    @ViewBuilder
    private func menuContent(current: SpaceRecord) -> some View {
        ForEach(tabs.orderedSpaces) { space in
            Button {
                tabs.setSpace(space.id, in: windowState)
            } label: {
                if space.id == current.id {
                    Label(space.name, systemImage: "checkmark")
                } else {
                    Text(space.name)
                }
            }
        }
        Divider()
        Button("New Space…", systemImage: "plus", action: onNewSpace)
        Button("Space Settings", systemImage: "gearshape") {
            SettingsNavigation.shared.currentSettingsTab = .spaces
            openSettings()
        }
    }
}
