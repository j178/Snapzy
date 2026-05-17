//
//  QuickAccessCoreTests.swift
//  SnapzyTests
//
//  Unit tests for Quick Access models and countdown behavior.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessCoreTests: XCTestCase {
  // Keep MainActor ObservableObjects alive for the test process; XCTest scope
  // cleanup can crash while deinitializing app-level observable stores.
  private static var retainedActionStores: [QuickAccessActionConfigurationStore] = []
  private static var retainedPinWindowStates: [QuickAccessPinWindowState] = []

  func testQuickAccessItem_formatsVideoDurationAndOmitsInvalidDurations() {
    let thumbnail = NSImage(size: CGSize(width: 16, height: 16))
    let video = QuickAccessItem(
      url: URL(fileURLWithPath: "/tmp/demo.mov"),
      thumbnail: thumbnail,
      duration: 90.9
    )
    let invalidVideo = QuickAccessItem(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/bad.mov"),
      thumbnail: thumbnail,
      capturedAt: Date(),
      itemType: .video,
      duration: -.infinity
    )
    let screenshot = QuickAccessItem(
      url: URL(fileURLWithPath: "/tmp/demo.png"),
      thumbnail: thumbnail
    )

    XCTAssertTrue(video.isVideo)
    XCTAssertEqual(video.formattedDuration, "01:30s")
    XCTAssertNil(invalidVideo.formattedDuration)
    XCTAssertFalse(screenshot.isVideo)
    XCTAssertNil(screenshot.formattedDuration)
  }

  func testQuickAccessProcessingState_identifiesProcessingOnly() {
    XCTAssertFalse(QuickAccessProcessingState.idle.isProcessing)
    XCTAssertTrue(QuickAccessProcessingState.processing(progress: nil).isProcessing)
    XCTAssertTrue(QuickAccessProcessingState.processing(progress: 0.4).isProcessing)
    XCTAssertFalse(QuickAccessProcessingState.complete.isProcessing)
    XCTAssertFalse(QuickAccessProcessingState.failed.isProcessing)
  }

  func testQuickAccessItemEquality_tracksMutablePresentationState() {
    let id = UUID()
    let thumbnail = NSImage(size: CGSize(width: 16, height: 16))
    let capturedAt = Date()
    let thumbnailVersion = UUID()
    let base = QuickAccessItem(
      id: id,
      url: URL(fileURLWithPath: "/tmp/demo.png"),
      thumbnail: thumbnail,
      capturedAt: capturedAt,
      itemType: .screenshot,
      duration: nil,
      thumbnailVersion: thumbnailVersion
    )
    var uploaded = base
    uploaded.cloudURL = URL(string: "https://cdn.example.com/demo.png")

    XCTAssertEqual(base, base)
    XCTAssertNotEqual(base, uploaded)

    var pinned = base
    pinned.isPinned = true
    XCTAssertNotEqual(base, pinned)
  }

  func testQuickAccessPinWindowSizing_enforcesMinimumInteractiveSizeForTinyImages() {
    let sizes = QuickAccessPinWindowSizing.sizes(
      for: CGSize(width: 24, height: 16),
      visibleSize: CGSize(width: 1440, height: 900)
    )
    let minimumSize = QuickAccessPinWindowSizing.minimumInteractiveSize

    XCTAssertGreaterThanOrEqual(sizes.base.width, minimumSize.width)
    XCTAssertGreaterThanOrEqual(sizes.base.height, minimumSize.height)
    XCTAssertLessThanOrEqual(sizes.base.width, sizes.max.width)
    XCTAssertLessThanOrEqual(sizes.base.height, sizes.max.height)
  }

  func testQuickAccessPinWindowState_clampsZoomToInteractiveMinimum() {
    let minimumSize = QuickAccessPinWindowSizing.minimumInteractiveSize
    let image = NSImage(size: CGSize(width: 24, height: 16))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/tiny.png"),
      image: image,
      thumbnail: image,
      baseSize: minimumSize,
      maxSize: CGSize(width: 1200, height: 900)
    )
    Self.retainedPinWindowStates.append(state)

    let displaySize = state.setZoomPercent(50)

    XCTAssertEqual(displaySize.width, minimumSize.width, accuracy: 0.001)
    XCTAssertEqual(displaySize.height, minimumSize.height, accuracy: 0.001)
    XCTAssertEqual(state.zoomPercent, 100)
    XCTAssertFalse(state.zoomMenuPercents.contains(50))
  }

  func testQuickAccessPinWindow_levelSurvivesFloatingPanelConfiguration() {
    let image = NSImage(size: CGSize(width: 24, height: 16))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/pinned.png"),
      image: image,
      thumbnail: image,
      baseSize: CGSize(width: 320, height: 220),
      maxSize: CGSize(width: 1200, height: 900)
    )
    Self.retainedPinWindowStates.append(state)

    let window = QuickAccessPinWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
      state: state
    )
    defer { window.close() }

    XCTAssertTrue(window.isFloatingPanel)
    XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue + 1)
  }

  func testQuickAccessPanel_interactiveRegionTracksVisibleCardsOnly() {
    let panelHeight =
      QuickAccessLayout.scaledCardHeight(1) * 5
      + QuickAccessLayout.cardSpacing * 4
      + QuickAccessLayout.containerPadding * 2
    let panel = QuickAccessPanel(
      contentRect: NSRect(x: 100, y: 100, width: 204, height: panelHeight)
    )
    defer { panel.close() }

    panel.updatePassthroughRegion(itemCount: 1, scale: 1)

    XCTAssertEqual(
      QuickAccessPanel.interactiveContentHeight(itemCount: 1, scale: 1, panelHeight: panelHeight),
      QuickAccessLayout.cardHeight + QuickAccessLayout.containerPadding * 2,
      accuracy: 0.001
    )
    XCTAssertTrue(panel.containsInteractivePoint(NSPoint(x: 150, y: 120)))
    XCTAssertFalse(panel.containsInteractivePoint(NSPoint(x: 150, y: panel.frame.maxY - 10)))
  }

  func testQuickAccessActionConfigurationStore_usesDefaultOrderAndEnabledActions() {
    let defaults = makeIsolatedDefaults()
    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertEqual(store.actionOrder, QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(store.orderedActions(includeDisabled: false), QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(store.slotAssignments, QuickAccessActionSlot.defaultAssignments)
    XCTAssertTrue(store.isEnabled(.pinToScreen))
  }

  func testQuickAccessActionKind_contextMenuOrderKeepsCloseAndDeleteAtEnd() {
    let configuredOrder: [QuickAccessActionKind] = [
      .copy,
      .saveOrOpen,
      .dismiss,
      .delete,
      .edit,
      .uploadToCloud,
      .pinToScreen,
    ]

    XCTAssertEqual(
      QuickAccessActionKind.contextMenuOrder(from: configuredOrder),
      [.copy, .saveOrOpen, .edit, .uploadToCloud, .pinToScreen, .dismiss, .delete]
    )
  }

  func testQuickAccessActionConfigurationStore_filtersUnknownIdsAndAppendsMissingActions() {
    let defaults = makeIsolatedDefaults()
    defaults.set(
      [
        QuickAccessActionKind.delete.rawValue,
        "future-action",
        QuickAccessActionKind.copy.rawValue,
        QuickAccessActionKind.copy.rawValue,
      ],
      forKey: PreferencesKeys.quickAccessActionOrder
    )
    defaults.set(
      [
        QuickAccessActionKind.copy.rawValue,
        "future-action",
      ],
      forKey: PreferencesKeys.quickAccessEnabledActions
    )

    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertEqual(
      store.actionOrder,
      [.delete, .copy, .saveOrOpen, .dismiss, .edit, .uploadToCloud, .pinToScreen]
    )
    XCTAssertEqual(store.orderedActions(includeDisabled: false), [.copy])
  }

  func testQuickAccessActionConfigurationStore_preservesExplicitPinToScreenDisable() {
    let defaults = makeIsolatedDefaults()
    defaults.set(
      QuickAccessActionKind.defaultOrder.map(\.rawValue),
      forKey: PreferencesKeys.quickAccessActionOrder
    )
    defaults.set(
      QuickAccessActionKind.defaultOrder
        .filter { $0 != .pinToScreen }
        .map(\.rawValue),
      forKey: PreferencesKeys.quickAccessEnabledActions
    )

    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertFalse(store.isEnabled(.pinToScreen))
    XCTAssertFalse(store.orderedActions(includeDisabled: false).contains(.pinToScreen))
  }

  func testQuickAccessActionConfigurationStore_togglesMovesAndPersistsActions() {
    let defaults = makeIsolatedDefaults()
    let store = makeActionConfigurationStore(defaults: defaults)

    store.setEnabled(.uploadToCloud, enabled: false)
    store.moveAction(from: IndexSet(integer: 0), to: 3)

    XCTAssertFalse(store.isEnabled(.uploadToCloud))
    XCTAssertEqual(
      store.actionOrder,
      [.saveOrOpen, .dismiss, .copy, .delete, .edit, .uploadToCloud, .pinToScreen]
    )
    XCTAssertEqual(store.slotAssignments, QuickAccessActionSlot.defaultAssignments)

    let reloadedStore = makeActionConfigurationStore(defaults: defaults)
    XCTAssertFalse(reloadedStore.isEnabled(.uploadToCloud))
    XCTAssertEqual(reloadedStore.actionOrder, store.actionOrder)
    XCTAssertEqual(reloadedStore.slotAssignments, QuickAccessActionSlot.defaultAssignments)

    reloadedStore.assignAction(.uploadToCloud, to: .centerTop)
    reloadedStore.clearSlot(.bottomLeading)

    XCTAssertEqual(reloadedStore.action(in: .centerTop), .uploadToCloud)
    XCTAssertNil(reloadedStore.action(in: .bottomTrailing))
    XCTAssertNil(reloadedStore.action(in: .bottomLeading))

    let placementReload = makeActionConfigurationStore(defaults: defaults)
    XCTAssertEqual(placementReload.action(in: .centerTop), .uploadToCloud)
    XCTAssertNil(placementReload.action(in: .bottomTrailing))
    XCTAssertNil(placementReload.action(in: .bottomLeading))

    placementReload.resetToDefaults()
    XCTAssertEqual(placementReload.actionOrder, QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(placementReload.orderedActions(includeDisabled: false), QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(placementReload.slotAssignments, QuickAccessActionSlot.defaultAssignments)
  }

  func testQuickAccessActionConfigurationStore_filtersSlotAssignmentsAndPreservesEmptySlots() {
    let defaults = makeIsolatedDefaults()
    defaults.set(
      [
        QuickAccessActionSlot.centerTop.rawValue: "future-action",
        QuickAccessActionSlot.centerBottom.rawValue: "",
        QuickAccessActionSlot.topTrailing.rawValue: QuickAccessActionKind.delete.rawValue,
        QuickAccessActionSlot.topLeading.rawValue: QuickAccessActionKind.delete.rawValue,
      ],
      forKey: PreferencesKeys.quickAccessActionSlotAssignments
    )

    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertNil(store.action(in: .centerTop))
    XCTAssertNil(store.action(in: .centerBottom))
    XCTAssertEqual(store.action(in: .topTrailing), .delete)
    XCTAssertNil(store.action(in: .topLeading))
    XCTAssertEqual(store.action(in: .bottomLeading), .edit)
    XCTAssertEqual(store.action(in: .bottomTrailing), .uploadToCloud)
  }

  func testQuickAccessCountdownTimer_pauseResumePreservesRemainingTime() async throws {
    var didExpire = false
    let expiration = expectation(description: "timer expires after resume")
    let clock = ManualQuickAccessCountdownTimerClock()
    let timer = QuickAccessCountdownTimer(duration: 0.08, clock: clock) {
      didExpire = true
      expiration.fulfill()
    }

    timer.start()
    await clock.waitForSleepCallCount(1)
    clock.advance(by: 0.03)
    timer.pause()

    XCTAssertTrue(timer.isPaused)
    XCTAssertFalse(timer.isRunning)

    clock.advance(by: 0.12)
    await Task.yield()
    XCTAssertFalse(didExpire)

    timer.resume()
    XCTAssertTrue(timer.isRunning)

    await clock.waitForSleepCallCount(2)
    clock.advance(by: 0.05)

    await fulfillment(of: [expiration], timeout: 1.0)
    XCTAssertTrue(didExpire)
  }

  func testQuickAccessCountdownTimer_cancelPreventsExpiration() async throws {
    var didExpire = false
    let clock = ManualQuickAccessCountdownTimerClock()
    let timer = QuickAccessCountdownTimer(duration: 0.03, clock: clock) {
      didExpire = true
    }

    timer.start()
    await clock.waitForSleepCallCount(1)
    timer.cancel()
    clock.advance(by: 0.08)
    await Task.yield()

    XCTAssertFalse(didExpire)
    XCTAssertFalse(timer.isRunning)
    XCTAssertFalse(timer.isPaused)
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "SnapzyTests.QuickAccess.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeActionConfigurationStore(
    defaults: UserDefaults
  ) -> QuickAccessActionConfigurationStore {
    let store = QuickAccessActionConfigurationStore(defaults: defaults)
    Self.retainedActionStores.append(store)
    return store
  }
}

@MainActor
private final class ManualQuickAccessCountdownTimerClock: QuickAccessCountdownTimerClock {
  private struct SleepRequest {
    let wakeTime: TimeInterval
    let continuation: CheckedContinuation<Void, Never>
  }

  private(set) var now: TimeInterval = 0
  private var sleepRequests: [SleepRequest] = []
  private var sleepCallCount = 0
  private var sleepCallWaiters: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func sleep(for duration: TimeInterval) async {
    await withCheckedContinuation { continuation in
      sleepCallCount += 1
      resumeSatisfiedSleepCallWaiters()

      let wakeTime = now + max(0, duration)
      guard wakeTime > now else {
        continuation.resume()
        return
      }

      sleepRequests.append(SleepRequest(wakeTime: wakeTime, continuation: continuation))
    }
  }

  func advance(by duration: TimeInterval) {
    now += duration

    var readyContinuations: [CheckedContinuation<Void, Never>] = []
    sleepRequests.removeAll { request in
      guard request.wakeTime <= now else { return false }
      readyContinuations.append(request.continuation)
      return true
    }

    readyContinuations.forEach { $0.resume() }
  }

  func waitForSleepCallCount(_ expectedCount: Int) async {
    guard sleepCallCount < expectedCount else { return }

    await withCheckedContinuation { continuation in
      sleepCallWaiters.append((expectedCount, continuation))
    }
  }

  private func resumeSatisfiedSleepCallWaiters() {
    var readyContinuations: [CheckedContinuation<Void, Never>] = []
    sleepCallWaiters.removeAll { waiter in
      guard sleepCallCount >= waiter.expectedCount else { return false }
      readyContinuations.append(waiter.continuation)
      return true
    }

    readyContinuations.forEach { $0.resume() }
  }
}
