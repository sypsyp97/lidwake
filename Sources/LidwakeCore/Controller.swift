import Foundation
import os

private let log = Logger(subsystem: "dev.lidwake", category: "controller")

public protocol InputsProvider: Sendable {
  func inputs() -> Inputs
}

/// Applies each `Decision` to the system. Owns `SleepDisabled` only when it set the flag
/// itself, and records that in the journal so a later process can undo it.
public final class Controller {
  private let provider: InputsProvider
  private let sleep: SleepControl
  private let assertion: AssertionHolder
  private let store: JournalStore
  private let probe: ProcessProbe
  private let settle: TimeInterval
  private var journal = Journal()
  /// The journal as last written to disk; `persist` writes only when `journal` differs.
  private var saved = Journal()
  private var lastOutcome: Outcome?

  public init(
    provider: InputsProvider, sleep: SleepControl, assertion: AssertionHolder,
    store: JournalStore, probe: ProcessProbe, settle: TimeInterval = Decision.defaultSettle
  ) {
    self.provider = provider
    self.sleep = sleep
    self.assertion = assertion
    self.store = store
    self.probe = probe
    self.settle = settle
  }

  /// Reloads the journal of a previous process. Ownership survives the restart: only a
  /// successful `setSleepDisabled(false)` drops it, because a crashed run's pmset child
  /// may still change the flag.
  public func start(now: Date) {
    journal = store.load()
    saved = journal
  }

  @discardableResult
  public func tick(now: Date) -> Outcome {
    let outcome = Decision.evaluate(
      provider.inputs(), now: now, lastActive: journal.lastActive, settle: settle)
    journal.lastActive = outcome.lastActive
    applyFlag(hold: outcome.hold)
    persist()
    applyAssertion(hold: outcome.hold)
    if outcome.hold != lastOutcome?.hold || outcome.reason != lastOutcome?.reason {
      log.info(
        "hold=\(outcome.hold, privacy: .public) reason=\(outcome.reason.rawValue, privacy: .public)"
      )
    }
    lastOutcome = outcome
    return outcome
  }

  public func stop() {
    if !orphanAlive() && journal.owned { clear() }
    persist()
    assertion.release()
  }

  /// Holding acts only on a flag that reads false: `true` is the user's setting or already
  /// ours, `nil` is unreadable. Releasing clears the flag only when it is ours.
  private func applyFlag(hold: Bool) {
    guard !orphanAlive() else { return }
    guard hold else {
      if journal.owned { clear() }
      return
    }
    guard sleep.isSleepDisabled() == false else { return }
    if journal.owned {
      write(true)
    } else {
      claim()
    }
  }

  /// A recorded pmset child, possibly from a crashed run, can still change the flag; no
  /// write may race it. A stopped child was never resumed, so it never ran pmset and is
  /// killed. Once the child is gone the record is dropped.
  private func orphanAlive() -> Bool {
    guard let pending = journal.pending else { return false }
    switch probe.state(pending) {
    case .gone:
      journal.pending = nil
      return false
    case .stopped:
      log.info("killing never-resumed pmset child pid \(pending.pid, privacy: .public)")
      probe.kill(pending)
      return true
    case .running:
      log.info("waiting for pmset child pid \(pending.pid, privacy: .public)")
      return true
    }
  }

  /// Ownership is saved with the pending child before the child runs, so a crash in
  /// between leaves a claim that a later tick re-applies or clears.
  private func claim() {
    journal.owned = true
    journal.owned = write(true)
  }

  private func clear() {
    if write(false) { journal.owned = false }
  }

  /// The one path to `setSleepDisabled`: the child's identity is saved with the current
  /// journal before the child runs. The caller saves `pending = nil` with the outcome.
  @discardableResult
  private func write(_ on: Bool) -> Bool {
    defer { journal.pending = nil }
    do {
      try sleep.setSleepDisabled(on) { identity in
        journal.pending = identity
        try save()
      }
      log.info("SleepDisabled=\(on ? 1 : 0, privacy: .public) set")
      return true
    } catch {
      log.error(
        "cannot set SleepDisabled=\(on ? 1 : 0, privacy: .public): \(error, privacy: .public)")
      return false
    }
  }

  private func applyAssertion(hold: Bool) {
    guard hold else { return assertion.release() }
    do {
      try assertion.hold()
    } catch {
      log.error("cannot hold power assertion: \(error, privacy: .public)")
    }
  }

  /// True when the disk holds `journal`.
  @discardableResult
  private func persist() -> Bool {
    do {
      try save()
      return true
    } catch {
      log.error("cannot save journal: \(error, privacy: .public)")
      return false
    }
  }

  private func save() throws {
    guard journal != saved else { return }
    try store.save(journal)
    saved = journal
  }
}
