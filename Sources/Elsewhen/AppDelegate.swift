import AppKit
import Combine
import ElsewhenCore
import SwiftUI

/// The menu bar item and the panel it opens: Omarchy's bar button and
/// KeyboardPanel, as an NSStatusItem and a popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private var model: PanelModel!
  private var statusItem: NSStatusItem!
  private var popover: NSPopover!
  private var keyMonitor: Any?
  private var settingsWindow: NSWindow?
  private let menuBarTicker = Ticker()
  private var menuBarShown: String?
  private var observers: Set<AnyCancellable> = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let dir = ProcessInfo.processInfo.environment["ELSEWHEN_SNAPSHOT_DIR"] {
      Snapshots.render(to: URL(fileURLWithPath: dir))
      NSApp.terminate(nil)
      return
    }

    model = PanelModel()
    model.onClose = { [weak self] in self?.closePanel() }
    model.onMoveClock = { [weak self] city, zone in self?.askToMoveClock(city: city, zone: zone) }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      let image = NSImage(systemSymbolName: "globe.europe.africa.fill", accessibilityDescription: L10n.t("elsewhen.worldClock", "World clock"))
        ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
      image?.isTemplate = true
      button.image = image
      button.toolTip = L10n.t("elsewhen.worldClock", "World clock")
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    let host = NSHostingController(rootView: PanelView(model: model))
    host.sizingOptions = [.preferredContentSize]
    popover.contentViewController = host

    // The menu bar clock follows the list and the settings as they change, and the minute as it turns.
    model.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateMenuBarClock() } }
      .store(in: &observers)
    updateMenuBarClock()
    scheduleMenuBarTick()
  }

  // MARK: the menu bar clock

  /// "Tokyo 19:40" beside the icon, or the icon alone. Only a change touches the menu bar.
  private func updateMenuBarClock() {
    guard let button = statusItem?.button else { return }
    let text = model.menuBarText()
    if text == menuBarShown { return }
    menuBarShown = text
    if let text {
      button.title = " " + text
      button.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
      button.imagePosition = .imageLeading
      statusItem.length = NSStatusItem.variableLength
    } else {
      button.title = ""
      button.imagePosition = .imageOnly
      statusItem.length = NSStatusItem.squareLength
    }
  }

  /// Wakes just after each minute turns, not every second.
  private func scheduleMenuBarTick() {
    let now = Date().timeIntervalSince1970
    menuBarTicker.once(after: 60 - now.truncatingRemainder(dividingBy: 60) + 0.05) { [weak self] in
      guard let self else { return }
      self.model.tick()
      self.updateMenuBarClock()
      self.scheduleMenuBarTick()
    }
  }

  // MARK: the panel

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      showMenu(sender)
    } else {
      togglePanel()
    }
  }

  func togglePanel() {
    if popover.isShown { closePanel() } else { openPanel() }
  }

  func openPanel() {
    guard let button = statusItem.button else { return }
    model.setOpened(true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    NSApp.activate(ignoringOtherApps: true)
    popover.contentViewController?.view.window?.makeKey()
    installKeyMonitor()
  }

  func closePanel() {
    if popover.isShown { popover.performClose(nil) }
  }

  func popoverDidClose(_ notification: Notification) {
    model.setOpened(false)
    removeKeyMonitor()
  }

  /// The panel's keys, ahead of the popover's own handling (which would close it on Escape).
  private func installKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.popover.isShown, event.window === self.popover.contentViewController?.view.window else { return event }
      let chars = event.charactersIgnoringModifiers ?? ""
      if event.modifierFlags.contains(.command) {
        switch chars {
        case "q": NSApp.terminate(nil); return nil
        case ",": self.openSettings(); return nil
        case "w": self.closePanel(); return nil
        default: return event
        }
      }
      let editing = event.window?.firstResponder is NSTextView
      let handled = self.model.handleKey(code: event.keyCode, characters: chars, modifiers: event.modifierFlags, editing: editing)
      return handled ? nil : event
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  // MARK: the menu

  private func showMenu(_ button: NSStatusBarButton) {
    let menu = NSMenu()
    menu.addItem(item(L10n.t("mac.refresh", "Refresh"), #selector(refresh), "r"))
    menu.addItem(item(L10n.t("mac.settings", "Settings…"), #selector(openSettings), ","))
    menu.addItem(.separator())
    menu.addItem(item(L10n.t("mac.about", "About Elsewhen"), #selector(showAbout), ""))
    menu.addItem(item(L10n.t("mac.quit", "Quit Elsewhen"), #selector(quit), "q"))
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
  }

  private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  @objc private func refresh() { model.refreshFacts() }

  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [
      .credits: NSAttributedString(string: "A world clock: the time in several cities at once, with a spinnable globe.\n"
        + "Elsewhen by Jason Fried for Omarchy; native macOS port.\nWeather and places: Open-Meteo. Coastlines: Natural Earth.")
    ])
  }

  @objc func openSettings() {
    closePanel()
    if settingsWindow == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
      window.title = L10n.t("mac.settingsTitle", "Elsewhen Settings")
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  // MARK: here, on another zone

  /// macOS keeps the time zone in System Settings; Elsewhen cannot move it, so it asks.
  func askToMoveClock(city: String, zone: String) {
    let alert = NSAlert()
    alert.messageText = L10n.t("mac.moveClockTitle", "Move this Mac's clock to %1?", city)
    alert.informativeText = L10n.t("mac.moveClockBody",
      "%1 keeps %2 time. macOS sets the time zone in System Settings → General → Date & Time. Once this Mac is on %2, Elsewhen counts %1 as here.",
      city, zone)
    alert.addButton(withTitle: L10n.t("mac.openDateTime", "Open Date & Time Settings"))
    alert.addButton(withTitle: L10n.t("mac.cancel", "Cancel"))
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }
}
