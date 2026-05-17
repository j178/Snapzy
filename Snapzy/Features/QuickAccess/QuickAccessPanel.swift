//
//  QuickAccessPanel.swift
//  Snapzy
//
//  NSPanel subclass for quick access screenshot overlay
//

import AppKit
import Foundation

/// Non-activating floating panel for screenshot previews
@MainActor
final class QuickAccessPanel: NSPanel {
  private var visibleItemCount = 0
  private var overlayScale: CGFloat = 1
  private var localMouseMonitor: Any?
  private var globalMouseMonitor: Any?

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configurePanel()
    installMouseMonitors()
  }

  override func close() {
    removeMouseMonitors()
    super.close()
  }

  func updatePassthroughRegion(itemCount: Int, scale: CGFloat) {
    visibleItemCount = max(0, itemCount)
    overlayScale = max(0.1, scale)
    refreshMousePassthrough()
  }

  func containsInteractivePoint(_ screenPoint: NSPoint) -> Bool {
    guard visibleItemCount > 0 else { return false }

    let activeHeight = Self.interactiveContentHeight(
      itemCount: visibleItemCount,
      scale: overlayScale,
      panelHeight: frame.height
    )
    let interactiveRect = NSRect(
      x: frame.minX,
      y: frame.minY,
      width: frame.width,
      height: activeHeight
    )
    return interactiveRect.contains(screenPoint)
  }

  static func interactiveContentHeight(itemCount: Int, scale: CGFloat, panelHeight: CGFloat) -> CGFloat {
    guard itemCount > 0 else { return 0 }

    let itemCount = max(0, itemCount)
    let scale = max(0.1, scale)
    let cardHeight = QuickAccessLayout.scaledCardHeight(scale)
    let spacing = CGFloat(max(0, itemCount - 1)) * QuickAccessLayout.cardSpacing
    let contentHeight = CGFloat(itemCount) * cardHeight + spacing + QuickAccessLayout.containerPadding * 2
    return min(panelHeight, contentHeight)
  }

  private func configurePanel() {
    level = .floating
    isFloatingPanel = true
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false  // Cards have their own shadows
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    acceptsMouseMovedEvents = true
    ignoresMouseEvents = false
  }

  private func installMouseMonitors() {
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved,
      .leftMouseDragged,
      .rightMouseDragged,
      .otherMouseDragged,
    ]

    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        self?.refreshMousePassthrough()
      }
      return event
    }

    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      Task { @MainActor in
        self?.refreshMousePassthrough()
      }
    }
  }

  private func removeMouseMonitors() {
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
      self.localMouseMonitor = nil
    }
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
  }

  private func refreshMousePassthrough() {
    ignoresMouseEvents = !containsInteractivePoint(NSEvent.mouseLocation)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
