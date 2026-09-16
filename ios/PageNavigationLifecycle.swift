import CoreGraphics
import PDFKit
import PencilKit
import UIKit

struct InkSignPdfEdgeNavigationGesture {
  let previousEligible: Bool
  let nextEligible: Bool
  let isRTL: Bool
  let deadZone: CGFloat
  let armDistance: CGFloat
}

protocol InkSignPdfPageTurnPreviewScheduler: AnyObject {
  func schedule(
    _ request: InkSignPdfPageTurnPreviewRequest,
    completion: @escaping (UIImage?) -> Void)
}

final class InkSignPdfDispatchPreviewScheduler: InkSignPdfPageTurnPreviewScheduler {
  private let queue = DispatchQueue(
    label: "ReactNativeInkSignPdf.pageTurnPreview",
    qos: .userInitiated)
  private let renderer: (InkSignPdfPageTurnPreviewRequest) -> UIImage?

  init(renderer: @escaping (InkSignPdfPageTurnPreviewRequest) -> UIImage? = {
    InkSignPdfPageTurnPreviewView.render(request: $0)
  }) {
    self.renderer = renderer
  }

  func schedule(
    _ request: InkSignPdfPageTurnPreviewRequest,
    completion: @escaping (UIImage?) -> Void
  ) {
    let renderer = self.renderer
    queue.async {
      let image = renderer(request)
      DispatchQueue.main.async {
        completion(image)
      }
    }
  }
}

protocol InkSignPdfPageTurnAnimationDriver: AnyObject {
  func start()
  func stop()
}

protocol InkSignPdfPageTurnAnimationDriverFactory: AnyObject {
  func make(
    duration: CFTimeInterval,
    update: @escaping (CGFloat) -> Void,
    finish: @escaping () -> Void
  ) -> InkSignPdfPageTurnAnimationDriver
}

final class ViewportAnimationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory {
  func make(
    duration: CFTimeInterval,
    update: @escaping (CGFloat) -> Void,
    finish: @escaping () -> Void
  ) -> InkSignPdfPageTurnAnimationDriver {
    ViewportAnimationDriver(duration: duration, update: update, finish: finish)
  }
}

/// Main-thread owner for the complete iOS page-turn transaction.
///
/// Owns the page-turn transaction and its two direction-local preview slots.
/// The view remains the owner of the document-navigation pipeline; this object
/// only supplies the presentation selected by an animated turn.
final class InkSignPdfPageTurnLifecycle {
  struct PreparedPreview {
    let key: InkSignPdfPageTurnPreviewKey
    let image: UIImage
    let frame: CGRect
  }

  struct RenderingPreview {
    let request: InkSignPdfPageTurnPreviewRequest
    let instance: UInt64
  }

  enum PreviewSlot {
    case absent
    case rendering(RenderingPreview)
    case ready(PreparedPreview)
  }

  struct StableContext: Equatable {
    let generation: UInt64
    let sourcePageIndex: Int
    let viewportSize: CGSize
    let density: CGFloat
    let isRTL: Bool
  }

  struct PullTransaction {
    let context: StableContext
    let gesture: InkSignPdfEdgeNavigationGesture
    let previews: [InkSignPdfEdgeNavigationPhysicalDirection: PreparedPreview]
    var physicalDirection: InkSignPdfEdgeNavigationPhysicalDirection?
    var targetDelta: Int?
    var targetPageIndex: Int?
    var progress: CGFloat
    var presentationOffset: CGFloat
    var hapticIssued: Bool
    var preview: PreparedPreview?
  }

  enum SettlementOutcome: Equatable {
    case rest
    case commit
  }

  final class SettlementTransaction {
    let token: UUID
    let startTransform: CGAffineTransform
    let outcome: SettlementOutcome
    let targetDelta: Int?
    let targetPageIndex: Int?
    let physicalDirection: InkSignPdfEdgeNavigationPhysicalDirection?
    let preview: PreparedPreview?
    var driver: InkSignPdfPageTurnAnimationDriver?

    init(token: UUID,
         startTransform: CGAffineTransform,
         outcome: SettlementOutcome,
         targetDelta: Int?,
         targetPageIndex: Int?,
         physicalDirection: InkSignPdfEdgeNavigationPhysicalDirection?,
         preview: PreparedPreview?) {
      self.token = token
      self.startTransform = startTransform
      self.outcome = outcome
      self.targetDelta = targetDelta
      self.targetPageIndex = targetPageIndex
      self.physicalDirection = physicalDirection
      self.preview = preview
    }
  }

  struct CommittedHandoff {
    enum Progress: Equatable {
      case starting
      case waiting(UInt64)
    }

    let targetDelta: Int
    let targetPageIndex: Int
    let physicalDirection: InkSignPdfEdgeNavigationPhysicalDirection
    let preview: PreparedPreview
    let progress: Progress
  }

  enum TurnState {
    case idle
    case pulling(PullTransaction)
    case settling(SettlementTransaction)
    case committed(CommittedHandoff)
  }

  weak var owner: PdfView?
  let previewView = InkSignPdfPageTurnPreviewView()
  private let previewScheduler: InkSignPdfPageTurnPreviewScheduler
  private let animationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory
  private(set) var phase: TurnState = .idle
  private(set) var previewSlots: [InkSignPdfEdgeNavigationPhysicalDirection: PreviewSlot] = [
    .left: .absent,
    .right: .absent
  ]
  private var nextPreviewInstance: UInt64 = 0
  private var disposed = false

  init(
    owner: PdfView,
    previewScheduler: InkSignPdfPageTurnPreviewScheduler = InkSignPdfDispatchPreviewScheduler(),
    animationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory = ViewportAnimationDriverFactory()
  ) {
    self.owner = owner
    self.previewScheduler = previewScheduler
    self.animationDriverFactory = animationDriverFactory
  }

  var gesture: InkSignPdfEdgeNavigationGesture? {
    guard case .pulling(let transaction) = phase else { return nil }
    return transaction.gesture
  }

  var pullingState: PullTransaction? {
    guard case .pulling(let transaction) = phase else { return nil }
    return transaction
  }

  var settlementDriver: InkSignPdfPageTurnAnimationDriver? {
    guard case .settling(let transaction) = phase else { return nil }
    return transaction.driver
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    stopSettlement()
    phase = .idle
    clearPreviewSlots()
    owner?.documentView.transform = .identity
    previewView.clear()
  }

  /// Cancels an unfinished turn before a command, document replacement, or
  /// mode change. A command may not retain an old neighbor snapshot.
  func cancelUncommittedTurn() {
    guard !disposed else { return }
    stopSettlement()
    phase = .idle
    clearPreviewSlots()
    clearPresentation()
  }

  func modeChanged(editing: Bool) {
    if editing { cancelUncommittedTurn() }
    else { stableContextChanged() }
  }

  func overlayDetached() {
    guard !disposed else { return }
    if case .committed = phase {
      owner?.container.bringSubviewToFront(previewView)
      return
    }
    cancelUncommittedTurn()
  }

  /// Reconciles the two direction-local slots only while no turn is active.
  func reconcilePreviews() {
    guard !disposed, case .idle = phase else { return }
    guard let owner,
          !owner.editMode,
          owner.pendingPageSwitchID == nil,
          let documentState = owner.documentState,
          owner.documentView.bounds.width > 0,
          owner.documentView.bounds.height > 0 else {
      clearPreviewSlots()
      clearPresentation()
      return
    }
    guard let context = currentStableContext() else { return }
    var desired = [InkSignPdfEdgeNavigationPhysicalDirection: InkSignPdfPageTurnPreviewRequest]()
    for direction in [InkSignPdfEdgeNavigationPhysicalDirection.left,
                      InkSignPdfEdgeNavigationPhysicalDirection.right] {
      if let request = previewRequest(for: direction,
                                      state: documentState,
                                      viewportSize: context.viewportSize,
                                      density: context.density,
                                      isRTL: context.isRTL) {
        desired[direction] = request
      }
    }

    var newRequests = [(InkSignPdfEdgeNavigationPhysicalDirection, RenderingPreview)]()
    for direction in [InkSignPdfEdgeNavigationPhysicalDirection.left,
                      InkSignPdfEdgeNavigationPhysicalDirection.right] {
      guard let request = desired[direction] else {
        previewSlots[direction] = .absent
        continue
      }
      switch previewSlots[direction] {
      case .some(.ready(let prepared)) where prepared.key == request.key:
        previewSlots[direction] = .ready(prepared)
      case .some(.rendering(let rendering)) where rendering.request.key == request.key:
        previewSlots[direction] = .rendering(rendering)
      default:
        nextPreviewInstance &+= 1
        let rendering = RenderingPreview(request: request, instance: nextPreviewInstance)
        previewSlots[direction] = .rendering(rendering)
        newRequests.append((direction, rendering))
      }
    }
    for (direction, rendering) in newRequests {
      submit(rendering, direction: direction)
    }
  }

  /// Routes stable-layout, focus, and view-mode notifications explicitly.
  /// An active pull whose captured context is no longer current must settle;
  /// settlements and committed handoffs retain their captured presentation.
  func stableContextChanged() {
    guard !disposed else { return }
    switch phase {
    case .idle:
      reconcilePreviews()
    case .pulling(let transaction):
      guard let current = currentStableContext(), current == transaction.context else {
        beginSettlement(outcome: .rest,
                        targetDelta: nil,
                        targetPageIndex: nil,
                        preview: transaction.preview,
                        physicalDirection: nil)
        return
      }
    case .settling, .committed:
      break
    }
  }

  private var readyPreviews: [InkSignPdfEdgeNavigationPhysicalDirection: PreparedPreview] {
    previewSlots.reduce(into: [:]) { result, item in
      if case .ready(let preview) = item.value {
        result[item.key] = preview
      }
    }
  }

  private func clearPreviewSlots() {
    previewSlots[.left] = .absent
    previewSlots[.right] = .absent
  }

  private func currentStableContext() -> StableContext? {
    guard let owner,
          let state = owner.documentState,
          !owner.editMode,
          owner.pendingPageSwitchID == nil,
          owner.documentView.bounds.width > 0,
          owner.documentView.bounds.height > 0 else { return nil }
    return StableContext(
      generation: owner.generation,
      sourcePageIndex: state.activePageIndex,
      viewportSize: owner.documentView.bounds.size,
      density: max(UIScreen.main.scale, 1),
      isRTL: owner.documentView.effectiveUserInterfaceLayoutDirection == .rightToLeft)
  }

  private func submit(
    _ rendering: RenderingPreview,
    direction: InkSignPdfEdgeNavigationPhysicalDirection
  ) {
    let request = rendering.request
    let instance = rendering.instance
    previewScheduler.schedule(request) { [weak self] image in
      self?.previewCompleted(image,
                             request: request,
                             direction: direction,
                             instance: instance)
    }
  }

  func previewCompleted(
    _ image: UIImage?,
    request: InkSignPdfPageTurnPreviewRequest,
    direction: InkSignPdfEdgeNavigationPhysicalDirection,
    instance: UInt64
  ) {
    guard !disposed else { return }
    guard case .rendering(let current) = previewSlots[direction],
          current.instance == instance,
          current.request.key == request.key,
          let owner,
          owner.generation == request.key.generation,
          owner.documentView.effectiveUserInterfaceLayoutDirection ==
            (request.key.isRTL ? .rightToLeft : .leftToRight),
          let state = owner.documentState,
          let expected = previewRequest(for: direction,
                                        state: state,
                                        viewportSize: owner.documentView.bounds.size,
                                        density: max(UIScreen.main.scale, 1),
                                        isRTL: request.key.isRTL),
          expected.key == request.key else { return }
    if let image {
      previewSlots[direction] = .ready(PreparedPreview(key: request.key, image: image, frame: request.frame))
    } else {
      previewSlots[direction] = .absent
    }
  }

  func prepareForEdgeNavigationTouch(at location: CGPoint) -> Bool {
    if case .settling(let settlement) = phase {
      guard settlement.outcome == .rest else { return false }
      stopSettlement()
      phase = .idle
      clearPresentation()
      reconcilePreviews()
    }
    guard !disposed, let owner, !owner.editMode,
          owner.documentState != nil else { return false }
    switch phase {
    case .idle: break
    default: return false
    }
    guard let gesture = captureGesture(at: location) else { return false }
    let physicalDirections = [
      gesture.isRTL
        ? (gesture.nextEligible ? InkSignPdfEdgeNavigationPhysicalDirection.right : nil)
        : (gesture.previousEligible ? InkSignPdfEdgeNavigationPhysicalDirection.right : nil),
      gesture.isRTL
        ? (gesture.previousEligible ? InkSignPdfEdgeNavigationPhysicalDirection.left : nil)
        : (gesture.nextEligible ? InkSignPdfEdgeNavigationPhysicalDirection.left : nil)
    ].compactMap { $0 }
    let availableDirections = physicalDirections.filter {
      if case .some(.ready) = previewSlots[$0] { return true }
      return false
    }
    guard !availableDirections.isEmpty else { return false }
    guard let context = currentStableContext() else { return false }
    let previews = readyPreviews.filter { availableDirections.contains($0.key) }
    phase = .pulling(PullTransaction(context: context,
                                  gesture: gesture,
                                  previews: previews,
                                  physicalDirection: nil,
                                  targetDelta: nil,
                                  targetPageIndex: nil,
                                  progress: 0,
                                  presentationOffset: 0,
                                  hapticIssued: false,
                                  preview: nil))
    return true
  }

  func pullChanged(translation: CGPoint) {
    guard !disposed, let owner, !owner.editMode else { return }
    guard case .pulling(var transaction) = phase else { return }
    guard translation.x.isFinite, translation.y.isFinite else { return }
    let physical: InkSignPdfEdgeNavigationPhysicalDirection = translation.x >= 0 ? .right : .left
    let reversed = transaction.physicalDirection != nil && transaction.physicalDirection != physical
    let eligible = if physical == .right {
      transaction.gesture.isRTL ? transaction.gesture.nextEligible : transaction.gesture.previousEligible
    } else {
      transaction.gesture.isRTL ? transaction.gesture.previousEligible : transaction.gesture.nextEligible
    }
    guard abs(translation.x) >= transaction.gesture.deadZone,
          abs(translation.x) > abs(translation.y), eligible else {
      if transaction.progress > 0 || transaction.presentationOffset != 0 || transaction.preview != nil || transaction.physicalDirection != nil {
        beginSettlement(outcome: .rest,
                        targetDelta: nil,
                        targetPageIndex: nil,
                        preview: transaction.preview,
                        physicalDirection: nil)
      } else {
        phase = .pulling(PullTransaction(context: transaction.context,
                                      gesture: transaction.gesture,
                                      previews: transaction.previews,
                                      physicalDirection: nil,
                                      targetDelta: nil,
                                      targetPageIndex: nil,
                                      progress: 0,
                                      presentationOffset: 0,
                                      hapticIssued: false,
                                      preview: nil))
      }
      return
    }
    if reversed {
      beginSettlement(outcome: .rest,
                      targetDelta: nil,
                      targetPageIndex: nil,
                      preview: transaction.preview,
                      physicalDirection: nil)
      return
    }
    guard let preview = transaction.previews[physical] else {
      beginSettlement(outcome: .rest,
                      targetDelta: nil,
                      targetPageIndex: nil,
                      preview: transaction.preview,
                      physicalDirection: nil)
      return
    }
    let denominator = max(transaction.gesture.armDistance - transaction.gesture.deadZone, 1)
    let progress = min(max((abs(translation.x) - transaction.gesture.deadZone) / denominator, 0), 1)
    let resisted = min(40, max(abs(translation.x) - transaction.gesture.deadZone, 0) * 40 / denominator)
    let delta = Self.pageTurnTargetDelta(for: physical, isRTL: transaction.gesture.isRTL)
    transaction.physicalDirection = physical
    transaction.targetDelta = delta
    transaction.targetPageIndex = transaction.context.sourcePageIndex + delta
    transaction.progress = progress
    transaction.presentationOffset = physical == .right ? resisted : -resisted
    transaction.preview = preview
    phase = .pulling(transaction)
    applyPresentation(offset: transaction.presentationOffset,
                      progress: transaction.progress,
                      preview: preview)
    if transaction.progress >= 1 && !transaction.hapticIssued {
      transaction.hapticIssued = true
      phase = .pulling(transaction)
      let feedback = UIImpactFeedbackGenerator(style: .light)
      feedback.prepare()
      feedback.impactOccurred()
    }
  }

  func pullEnded() {
    guard !disposed, let owner, !owner.editMode,
          case .pulling(let transaction) = phase else { return }
    let shouldCommit = transaction.progress >= 1 &&
      transaction.targetDelta != nil && transaction.targetPageIndex != nil && transaction.preview != nil
    if shouldCommit {
      owner.edgeNavigationGestureRecognizer.isEnabled = false
      owner.documentView.gestureRecognizers?.forEach { $0.isEnabled = false }
      beginSettlement(outcome: .commit,
                      targetDelta: transaction.targetDelta,
                      targetPageIndex: transaction.targetPageIndex,
                      preview: transaction.preview,
                      physicalDirection: transaction.physicalDirection)
    } else {
      beginSettlement(outcome: .rest,
                      targetDelta: nil,
                      targetPageIndex: nil,
                      preview: transaction.preview,
                      physicalDirection: nil)
    }
  }

  func pullCancelled() {
    guard !disposed, let owner, !owner.editMode,
          case .pulling(let transaction) = phase else { return }
    beginSettlement(outcome: .rest,
                    targetDelta: nil,
                    targetPageIndex: nil,
                    preview: transaction.preview,
                    physicalDirection: nil)
  }

  private func beginSettlement(
    outcome: SettlementOutcome,
    targetDelta: Int?,
    targetPageIndex: Int?,
    preview: PreparedPreview?,
    physicalDirection: InkSignPdfEdgeNavigationPhysicalDirection?
  ) {
    guard let owner else { return }
    stopSettlement()
    let token = UUID()
    let startTransform = owner.documentView.transform
    let settlement = SettlementTransaction(token: token,
                                           startTransform: startTransform,
                                           outcome: outcome,
                                           targetDelta: targetDelta,
                                           targetPageIndex: targetPageIndex,
                                           physicalDirection: physicalDirection,
                                           preview: preview)
    phase = .settling(settlement)
    let driver = animationDriverFactory.make(duration: 0.18, update: { [weak self, weak owner] progress in
      guard let self, let owner, case .settling(let active) = self.phase,
            active.token == token else { return }
      switch outcome {
      case .rest:
        owner.documentView.transform = Self.interpolate(active.startTransform, to: .identity, progress: progress)
      case .commit:
        guard let physicalDirection else { return }
        let finalOffset = (physicalDirection == .right ? 1 : -1) * max(owner.bounds.width, 1)
        let end = CGAffineTransform(translationX: finalOffset, y: 0).scaledBy(x: 0.96, y: 0.96)
        owner.documentView.transform = Self.interpolate(active.startTransform, to: end, progress: progress)
      }
    }, finish: { [weak self, weak owner] in
      guard let self, let owner, case .settling(let active) = self.phase,
            active.token == token else { return }
      active.driver = nil
      switch active.outcome {
      case .rest:
        self.phase = .idle
        self.clearPresentation()
        self.reconcilePreviews()
      case .commit:
        guard let delta = active.targetDelta,
              let targetPageIndex = active.targetPageIndex,
              let preview = active.preview,
              let physicalDirection = active.physicalDirection else {
          self.phase = .idle
          self.clearPresentation()
          self.reconcilePreviews()
          return
        }
        self.phase = .committed(CommittedHandoff(
          targetDelta: delta,
          targetPageIndex: targetPageIndex,
          physicalDirection: physicalDirection,
          preview: preview,
          progress: .starting))
        owner.beginPageTurnCommit(targetPageIndex: targetPageIndex)
      }
    })
    settlement.driver = driver
    driver.start()
  }

  private static func interpolate(
    _ start: CGAffineTransform,
    to end: CGAffineTransform,
    progress: CGFloat
  ) -> CGAffineTransform {
    CGAffineTransform(a: start.a + (end.a - start.a) * progress,
                      b: start.b + (end.b - start.b) * progress,
                      c: start.c + (end.c - start.c) * progress,
                      d: start.d + (end.d - start.d) * progress,
                      tx: start.tx + (end.tx - start.tx) * progress,
                      ty: start.ty + (end.ty - start.ty) * progress)
  }

  private func stopSettlement() {
    if case .settling(let settlement) = phase {
      settlement.driver?.stop()
      settlement.driver = nil
    }
  }

  func cancelSettlement() {
    guard case .settling(let settlement) = phase,
          settlement.outcome == .rest else { return }
    stopSettlement()
    phase = .idle
    owner?.documentView.transform = .identity
    clearPresentation()
    reconcilePreviews()
  }

  func pageSwitchStarted(switchID: UInt64, targetPageIndex: Int) {
    guard case .committed(let handoff) = phase,
          handoff.targetPageIndex == targetPageIndex,
          handoff.progress == .starting else { return }
    phase = .committed(CommittedHandoff(
      targetDelta: handoff.targetDelta,
      targetPageIndex: handoff.targetPageIndex,
      physicalDirection: handoff.physicalDirection,
      preview: handoff.preview,
      progress: .waiting(switchID)))
    owner?.container.bringSubviewToFront(previewView)
  }

  @discardableResult
  func pageSwitchReady(switchID: UInt64) -> Bool {
    guard case .committed(let handoff) = phase,
          handoff.progress == .waiting(switchID) else { return false }
    phase = .idle
    clearPreviewSlots()
    clearPresentation()
    reconcilePreviews()
    return true
  }

  func pageSwitchCancelled(switchID: UInt64) {
    guard case .committed(let handoff) = phase,
          handoff.progress == .waiting(switchID) else { return }
    finishCommittedHandoff()
  }

  func pageSwitchFailed(switchID: UInt64) {
    guard case .committed(let handoff) = phase,
          handoff.progress == .waiting(switchID) else { return }
    finishCommittedHandoff()
  }

  func pageTurnCommitFailedBeforeStart() {
    guard case .committed(let handoff) = phase,
          handoff.progress == .starting else { return }
    finishCommittedHandoff()
  }

  private func finishCommittedHandoff() {
    phase = .idle
    clearPreviewSlots()
    clearPresentation()
    reconcilePreviews()
  }

  private func clearPresentation() {
    owner?.documentView.transform = .identity
    previewView.transform = .identity
    previewView.clear()
  }

  private func showPreview(_ preview: PreparedPreview) {
    guard let owner else { return }
    owner.container.insertSubview(previewView, belowSubview: owner.documentView)
    _ = previewView.install(image: preview.image, key: preview.key, frame: preview.frame)
  }

  private func applyPresentation(
    offset: CGFloat,
    progress: CGFloat,
    preview: PreparedPreview
  ) {
    guard let owner else { return }
    let shrinkProgress = min(max((progress - 0.72) / 0.28, 0), 1)
    let smooth = shrinkProgress * shrinkProgress * (3 - 2 * shrinkProgress)
    let scale = 1 - 0.04 * smooth
    owner.documentView.transform = CGAffineTransform(translationX: offset, y: 0)
      .scaledBy(x: scale, y: scale)
    showPreview(preview)
  }

  private func captureGesture(at location: CGPoint) -> InkSignPdfEdgeNavigationGesture? {
    guard let owner,
          let state = owner.documentState,
          let page = state.activePage.page,
          owner.documentView.bounds.width > 0,
          owner.documentView.bounds.height > 0,
          state.activePage.geometry.isValid else { return nil }
    let bounds = owner.documentView.bounds
    let pageBounds = owner.documentView.convert(page.bounds(for: .mediaBox), from: page)
    let edgeTolerance = 1 / max(UIScreen.main.scale, 1)
    guard location.y >= pageBounds.minY - edgeTolerance,
          location.y <= pageBounds.maxY + edgeTolerance,
          location.x >= pageBounds.minX - edgeTolerance,
          location.x <= pageBounds.maxX + edgeTolerance else { return nil }
    let leftPDF = owner.documentView.convert(CGPoint(x: bounds.minX, y: bounds.midY), to: page)
    let rightPDF = owner.documentView.convert(CGPoint(x: bounds.maxX, y: bounds.midY), to: page)
    let mediaBox = state.activePage.geometry.mediaBox
    let left = CGPoint(x: leftPDF.x - mediaBox.minX, y: mediaBox.maxY - leftPDF.y)
    let right = CGPoint(x: rightPDF.x - mediaBox.minX, y: mediaBox.maxY - rightPDF.y)
    let rotation = ((state.activePage.geometry.rotation % 360) + 360) % 360
    let usesCanonicalY = rotation == 90 || rotation == 270
    let leftAxis = usesCanonicalY ? left.y : left.x
    let rightAxis = usesCanonicalY ? right.y : right.x
    let pageLength = usesCanonicalY ? mediaBox.height : mediaBox.width
    let visibleLength = abs(rightAxis - leftAxis)
    let pointsPerPoint = visibleLength / bounds.width
    let onePixel = pointsPerPoint / max(UIScreen.main.scale, 1)
    guard pageLength.isFinite, pageLength > 0,
          visibleLength.isFinite, visibleLength > 0,
          onePixel.isFinite, onePixel > 0 else { return nil }
    let leftClamped = min(max(leftAxis, 0), pageLength)
    let rightClamped = min(max(rightAxis, 0), pageLength)
    let increasesToRight = rightAxis >= leftAxis
    let leftBoundary = increasesToRight ? 0.0 : pageLength
    let rightBoundary = increasesToRight ? pageLength : 0.0
    let atLeft = abs(leftClamped - leftBoundary) <= onePixel
    let atRight = abs(rightClamped - rightBoundary) <= onePixel
    let isRTL = owner.documentView.effectiveUserInterfaceLayoutDirection == .rightToLeft
    let visiblePageWidth = pageBounds.intersection(bounds).width
    let armDistance = visiblePageWidth * 0.30
    guard visiblePageWidth.isFinite, visiblePageWidth > 0,
          armDistance.isFinite, armDistance > 0 else { return nil }
    return InkSignPdfEdgeNavigationGesture(
      previousEligible: state.activePageIndex > 0 && (isRTL ? atRight : atLeft),
      nextEligible: state.activePageIndex + 1 < state.pages.count && (isRTL ? atLeft : atRight),
      isRTL: isRTL,
      deadZone: 8,
      armDistance: armDistance)
  }

  static func pageTurnTargetDelta(
    for direction: InkSignPdfEdgeNavigationPhysicalDirection,
    isRTL: Bool
  ) -> Int {
    switch (direction, isRTL) {
    case (.left, false), (.right, true): return 1
    case (.right, false), (.left, true): return -1
    }
  }

  func previewRequest(
    for direction: InkSignPdfEdgeNavigationPhysicalDirection,
    state: InkSignPdfDocumentState,
    viewportSize: CGSize,
    density: CGFloat,
    isRTL: Bool
  ) -> InkSignPdfPageTurnPreviewRequest? {
    guard let owner,
          state.pages.indices.contains(state.activePageIndex + Self.pageTurnTargetDelta(for: direction, isRTL: isRTL)) else { return nil }
    let targetIndex = state.activePageIndex + Self.pageTurnTargetDelta(for: direction, isRTL: isRTL)
    let target = state.pages[targetIndex]
    guard let layout = fitCenteredLayout(for: target.geometry) else { return nil }
    let mediaBox = target.geometry.mediaBox
    let key = InkSignPdfPageTurnPreviewKey(
      generation: owner.generation,
      sourcePageIndex: state.activePageIndex,
      targetPageIndex: targetIndex,
      direction: direction,
      targetScale: layout.scale,
      targetFocusX: mediaBox.midX,
      targetFocusY: mediaBox.midY,
      targetOriginX: layout.frame.minX,
      targetOriginY: layout.frame.minY,
      targetWidth: layout.frame.width,
      targetHeight: layout.frame.height,
      viewportWidth: viewportSize.width,
      viewportHeight: viewportSize.height,
      density: density,
      targetContentRevision: target.contentRevision,
      isRTL: isRTL)
    return InkSignPdfPageTurnPreviewRequest(
      key: key,
      sourceURL: state.sourceURL,
      drawingData: target.history.content.drawing.dataRepresentation(),
      textAnnotations: target.history.content.textAnnotations,
      size: layout.frame.size,
      frame: layout.frame)
  }

  private func fitCenteredLayout(for geometry: PageGeometry) -> (frame: CGRect, scale: CGFloat)? {
    guard let owner, geometry.isValid,
          owner.documentView.bounds.width > 0,
          owner.documentView.bounds.height > 0 else { return nil }
    let rotation = ((geometry.rotation % 360) + 360) % 360
    let width = rotation == 90 || rotation == 270 ? geometry.mediaBox.height : geometry.mediaBox.width
    let height = rotation == 90 || rotation == 270 ? geometry.mediaBox.width : geometry.mediaBox.height
    let scale = min(owner.documentView.bounds.width / width,
                    owner.documentView.bounds.height / height)
    guard scale.isFinite, scale > 0 else { return nil }
    let frame = CGRect(x: owner.documentView.bounds.midX - width * scale / 2,
                       y: owner.documentView.bounds.midY - height * scale / 2,
                       width: width * scale,
                       height: height * scale)
    guard frame.minX.isFinite, frame.minY.isFinite,
          frame.width.isFinite, frame.height.isFinite else { return nil }
    return (frame, scale)
  }
}
