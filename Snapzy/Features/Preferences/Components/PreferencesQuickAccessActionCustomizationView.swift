//
//  PreferencesQuickAccessActionCustomizationView.swift
//  Snapzy
//
//  Quick Access card preview and action ordering controls.
//

import SwiftUI

struct QuickAccessActionCustomizationView: View {
  @ObservedObject var manager: QuickAccessManager
  @ObservedObject private var actionStore = QuickAccessActionConfigurationStore.shared
  @ObservedObject private var swipeActionStore = QuickAccessSwipeActionStore.shared

  var body: some View {
    Section(L10n.PreferencesQuickAccess.previewSection) {
      HStack {
        Spacer()
        QuickAccessSettingsPreviewCard(
          scale: CGFloat(manager.overlayScale),
          actionStore: actionStore,
          swipeActionStore: swipeActionStore
        )
        Spacer()
      }
      .padding(.vertical, 10)
    }

    Section(L10n.PreferencesQuickAccess.quickActionsSection) {
      VStack(alignment: .leading, spacing: 10) {
        Text(L10n.PreferencesQuickAccess.quickActionsDescription)
          .font(.caption)
          .foregroundColor(.secondary)

        List {
          ForEach(actionStore.actionOrder) { action in
            QuickAccessActionConfigurationRow(
              action: action,
              assignedSlot: actionStore.assignedSlot(for: action),
              isEnabled: Binding(
                get: { actionStore.isEnabled(action) },
                set: { actionStore.setEnabled(action, enabled: $0) }
              )
            )
          }
          .onMove { source, destination in
            actionStore.moveAction(from: source, to: destination)
          }
        }
        .frame(minHeight: 190)
        .clipShape(RoundedRectangle(cornerRadius: 8))

        HStack {
          Spacer()
          Button(L10n.PreferencesQuickAccess.resetActions) {
            actionStore.resetToDefaults()
            swipeActionStore.resetToDefaults()
          }
        }
      }
      .padding(.vertical, 4)
    }
  }
}

private struct QuickAccessActionConfigurationRow: View {
  let action: QuickAccessActionKind
  let assignedSlot: QuickAccessActionSlot?
  @Binding var isEnabled: Bool

  var body: some View {
    HStack(spacing: 10) {
      actionLabel

      Spacer()

      placementBadge

      Toggle("", isOn: $isEnabled)
        .labelsHidden()
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onDrag {
      QuickAccessActionDragPayload.itemProvider(action: action, source: .actionList)
    } preview: {
      QuickAccessActionDragPreview(action: action)
    }
  }

  private var actionLabel: some View {
    HStack(spacing: 10) {
      Image(systemName: action.systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18)

      Text(action.settingsTitle)
        .lineLimit(1)
    }
  }

  private var placementBadge: some View {
    Text(assignedSlot?.settingsTitle ?? L10n.PreferencesQuickAccess.notOnCard)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.quaternary, in: Capsule())
  }
}

private struct QuickAccessActionDragPreview: View {
  let action: QuickAccessActionKind

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: action.systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16)

      Text(action.settingsTitle)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 4)
    .fixedSize(horizontal: true, vertical: false)
  }
}
