//
//  PreferencesQuickAccessActionDragPayload.swift
//  Snapzy
//
//  Plain-text drag payload for Quick Access action placement.
//

import Foundation
import UniformTypeIdentifiers

struct QuickAccessActionDragPayload {
  enum Source: Equatable {
    case actionList
    case preview(slot: QuickAccessActionSlot)
    case swipePreview(direction: QuickAccessSwipeDirection)
  }

  static let typeIdentifiers = [UTType.plainText.identifier]

  private static let marker = "com.snapzy.quick-access-action"

  let action: QuickAccessActionKind
  let source: Source

  static func itemProvider(action: QuickAccessActionKind, source: Source) -> NSItemProvider {
    NSItemProvider(object: Self(action: action, source: source).encoded as NSString)
  }

  static func load(from providers: [NSItemProvider], completion: @escaping (QuickAccessActionDragPayload) -> Void) {
    guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else {
      return
    }

    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
      let text: String?
      if let data = item as? Data {
        text = String(data: data, encoding: .utf8)
      } else {
        text = item as? String
      }

      guard let text,
            let payload = Self.parse(text) else {
        return
      }

      Task { @MainActor in
        completion(payload)
      }
    }
  }

  private var encoded: String {
    switch source {
    case .actionList:
      return "\(Self.marker)|list|\(action.rawValue)"
    case .preview(let slot):
      return "\(Self.marker)|preview|\(slot.rawValue)|\(action.rawValue)"
    case .swipePreview(let direction):
      return "\(Self.marker)|swipe|\(direction.rawValue)|\(action.rawValue)"
    }
  }

  private static func parse(_ text: String) -> QuickAccessActionDragPayload? {
    let parts = text.split(separator: "|").map(String.init)
    guard parts.first == marker else { return nil }

    if parts.count == 3,
       parts[1] == "list",
       let action = QuickAccessActionKind(rawValue: parts[2]) {
      return QuickAccessActionDragPayload(action: action, source: .actionList)
    }

    if parts.count == 4,
       parts[1] == "preview",
       let slot = QuickAccessActionSlot(rawValue: parts[2]),
       let action = QuickAccessActionKind(rawValue: parts[3]) {
      return QuickAccessActionDragPayload(action: action, source: .preview(slot: slot))
    }

    if parts.count == 4,
       parts[1] == "swipe",
       let direction = QuickAccessSwipeDirection(rawValue: parts[2]),
       let action = QuickAccessActionKind(rawValue: parts[3]) {
      return QuickAccessActionDragPayload(action: action, source: .swipePreview(direction: direction))
    }

    return nil
  }
}
