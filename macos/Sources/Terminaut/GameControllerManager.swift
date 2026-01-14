import Foundation
import GameController
import Combine
import Carbon.HIToolbox

/// Manages game controller input for Terminaut navigation
/// Designed for 8BitDo Pro 2 and similar controllers
class GameControllerManager: ObservableObject {
    static let shared = GameControllerManager()

    /// Current connected controller
    @Published var connectedController: GCController?

    /// Controller button events - views subscribe to these
    @Published var lastButtonPress: ControllerButton?

    /// D-pad direction events
    @Published var lastDirection: ControllerDirection?

    /// Right trigger held state (for voice dictation)
    @Published var rightTriggerHeld: Bool = false

    /// Right stick scroll value (-1 to 1, negative = scroll up, positive = scroll down)
    @Published var scrollValue: Float = 0

    /// Vim mode active state
    @Published var vimModeActive: Bool = false

    /// Select mode active (right stick sends Shift+Arrow for text selection)
    @Published var selectModeActive: Bool = false

    /// Is a controller currently connected?
    var isConnected: Bool { connectedController != nil }

    private var cancellables = Set<AnyCancellable>()
    private var scrollTimer: Timer?

    // MARK: - Button Types

    enum ControllerButton: String {
        case a = "A"           // Confirm (Enter) / vim: Enter
        case b = "B"           // vim: insert mode (i)
        case x = "X"           // vim: delete line (dd)
        case y = "Y"           // vim: yank line (yy)
        case leftBumper = "L"  // Previous tab / vim: undo (u)
        case rightBumper = "R" // Next tab / vim: paste (p)
        case start = "Start"   // Menu
        case select = "Select" // Return to launcher
        case leftPaddle = "L4" // Shift-Tab
        case rightPaddle = "R4" // Escape
        case leftStickClick = "L3" // Vim mode ON
        case rightStickClick = "R3" // Vim mode OFF
    }

    enum ControllerDirection: String {
        case up = "Up"
        case down = "Down"
        case left = "Left"
        case right = "Right"
    }

    // MARK: - Initialization

    private init() {
        setupControllerDiscovery()
    }

    /// Start watching for controllers
    func start() {
        // Check for already connected controllers
        if let controller = GCController.controllers().first {
            setupController(controller)
        }
    }

    /// Stop controller monitoring
    func stop() {
        connectedController?.extendedGamepad?.valueChangedHandler = nil
        connectedController = nil
    }

    // MARK: - Controller Discovery

    private func setupControllerDiscovery() {
        // Watch for controller connections
        NotificationCenter.default.publisher(for: .GCControllerDidConnect)
            .sink { [weak self] notification in
                if let controller = notification.object as? GCController {
                    print("🎮 Controller connected: \(controller.vendorName ?? "Unknown")")
                    self?.setupController(controller)
                }
            }
            .store(in: &cancellables)

        // Watch for controller disconnections
        NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)
            .sink { [weak self] notification in
                if let controller = notification.object as? GCController,
                   controller == self?.connectedController {
                    print("🎮 Controller disconnected")
                    self?.connectedController = nil
                }
            }
            .store(in: &cancellables)

        // Start wireless controller discovery
        GCController.startWirelessControllerDiscovery {
            print("🎮 Wireless controller discovery completed")
        }
    }

    // MARK: - Controller Setup

    private func setupController(_ controller: GCController) {
        connectedController = controller

        // Prefer extended gamepad (full controller with dual sticks)
        if let gamepad = controller.extendedGamepad {
            setupExtendedGamepad(gamepad)
        }
        // Fall back to micro gamepad (simpler controllers)
        else if let microGamepad = controller.microGamepad {
            setupMicroGamepad(microGamepad)
        }

        // Log controller info
        print("🎮 Controller product category: \(controller.productCategory)")
        if let battery = controller.battery {
            print("🎮 Battery: \(Int(battery.batteryLevel * 100))% (\(battery.batteryState.rawValue))")
        }
    }

    private func setupExtendedGamepad(_ gamepad: GCExtendedGamepad) {
        // D-pad
        gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
            self?.handleDpad(x: xValue, y: yValue)
        }

        // Face buttons - 8BitDo uses Nintendo layout in Switch mode
        // A = East (confirm), B = South (back), X = North, Y = West
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.a) }
        }

        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.b) }
        }

        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.x) }
        }

        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.y) }
        }

        // Bumpers
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.leftBumper) }
        }

        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.rightBumper) }
        }

        // Menu buttons
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.start) }
        }

        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.select) }
        }

        // Left stick can also be used for navigation
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            self?.handleThumbstick(x: xValue, y: yValue)
        }

        // Right trigger (R2) - Voice dictation (simulates holding backslash)
        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleRightTrigger(pressed: pressed)
        }

        // Right stick - Terminal scrolling
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, _, yValue in
            self?.handleRightThumbstick(y: yValue)
        }

        // Left stick click (L3) - Vim mode ON (program P1 paddle to L3)
        gamepad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed {
                self?.setVimMode(true)
                self?.handleButton(.leftStickClick)
            }
        }

        // Right stick click (R3) - Toggle select mode for text selection/copying
        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed {
                print("🎮 R3 clicked!")
                self?.toggleSelectMode()
                self?.handleButton(.rightStickClick)
            }
        }

        // Left trigger (L2) - Left paddle action (Shift-Tab)
        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.leftPaddle) }
        }

        // Note: 8BitDo Pro 2 back paddles are programmable on the controller itself
        // They can be mapped to any button. For now, we use L2 for Shift-Tab
        // and the physical back paddle can be programmed to L2 via 8BitDo Ultimate Software

        // Home button - could be used for special actions
        gamepad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed {
                print("🎮 Home button pressed")
            }
        }
    }

    // MARK: - Vim Mode

    private func setVimMode(_ active: Bool) {
        DispatchQueue.main.async {
            guard self.vimModeActive != active else { return }
            self.vimModeActive = active
            print("🎮 Vim mode: \(active ? "ON" : "OFF")")
        }
    }

    // MARK: - Select Mode (for text selection/copying)

    private func toggleSelectMode() {
        DispatchQueue.main.async {
            self.selectModeActive.toggle()
            print("🎮 Select mode: \(self.selectModeActive ? "ON" : "OFF")")

            // Stop scrolling when entering/exiting select mode
            if self.selectModeActive {
                self.stopScrolling()
            }
        }
    }

    // MARK: - Terminal Scrolling (Right Stick)

    private let scrollDeadzone: Float = 0.3

    private func handleRightThumbstick(y: Float) {
        // Apply deadzone
        if abs(y) < scrollDeadzone {
            if !selectModeActive {
                stopScrolling()
            }
            selectModeLastDirection = nil
            return
        }

        // Select mode: send Shift+Arrow keys for text selection
        if selectModeActive {
            let direction: ControllerDirection = y > 0 ? .up : .down
            print("🎮 Right stick in SELECT mode: y=\(y), direction=\(direction)")
            // Only fire on direction change to avoid key repeat flood
            if direction != selectModeLastDirection {
                selectModeLastDirection = direction
                sendSelectModeArrow(direction: direction)
            }
            return
        }

        print("🎮 Right stick in SCROLL mode: y=\(y)")

        // Scroll mode (default): scroll terminal
        // Invert: stick up (positive y) = scroll up (see earlier content)
        let scrollDirection = -y

        DispatchQueue.main.async {
            self.scrollValue = scrollDirection
        }

        startScrolling(direction: scrollDirection)
    }

    private var selectModeLastDirection: ControllerDirection?

    /// Send Shift+Arrow key for text selection in select mode
    private func sendSelectModeArrow(direction: ControllerDirection) {
        let keyCode: CGKeyCode
        switch direction {
        case .up: keyCode = 126
        case .down: keyCode = 125
        case .left: keyCode = 123
        case .right: keyCode = 124
        }

        // Create Shift+Arrow key event
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskShift
        keyUp.flags = .maskShift

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func startScrolling(direction: Float) {
        // Stop any existing timer
        scrollTimer?.invalidate()

        // Calculate scroll speed based on stick deflection
        let speed = abs(direction)
        let interval = Double(0.05 / speed)  // Faster when pushed further

        scrollTimer = Timer.scheduledTimer(withTimeInterval: max(0.02, interval), repeats: true) { [weak self] _ in
            self?.sendScrollEvent(direction: direction)
        }

        // Fire immediately
        sendScrollEvent(direction: direction)
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        DispatchQueue.main.async {
            self.scrollValue = 0
        }
    }

    private func sendScrollEvent(direction: Float) {
        // Create scroll wheel event
        // Positive direction = scroll up (content moves down), negative = scroll down
        // Use at least 1 line, scaled by direction magnitude
        let sign: Float = direction > 0 ? 1 : -1
        let scrollAmount = Int32(sign * max(1, abs(direction) * 2))  // 1-2 lines per tick

        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: scrollAmount, wheel2: 0, wheel3: 0) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Voice Dictation (Right Trigger)

    private func handleRightTrigger(pressed: Bool) {
        DispatchQueue.main.async {
            self.rightTriggerHeld = pressed
        }
        simulateBackslashKey(pressed: pressed)
    }

    /// Simulate holding/releasing the backslash key for Aqua voice dictation
    private func simulateBackslashKey(pressed: Bool) {
        // Backslash key code is 42 (kVK_ANSI_Backslash)
        let keyCode: CGKeyCode = 42

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: pressed) else {
            print("🎮 Failed to create keyboard event")
            return
        }

        event.post(tap: .cghidEventTap)
        print("🎮 Backslash key \(pressed ? "down" : "up") - Voice dictation \(pressed ? "activated" : "deactivated")")
    }

    private func setupMicroGamepad(_ gamepad: GCMicroGamepad) {
        gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
            self?.handleDpad(x: xValue, y: yValue)
        }

        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.a) }
        }

        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.handleButton(.b) }
        }
    }

    // MARK: - Input Handling

    private var lastDpadState: (x: Float, y: Float) = (0, 0)

    private func handleDpad(x: Float, y: Float) {
        // Debounce - only trigger on state change
        guard (x, y) != lastDpadState else { return }
        lastDpadState = (x, y)

        // Map to discrete directions
        if y > 0.5 {
            handleDirection(.up)
        } else if y < -0.5 {
            handleDirection(.down)
        }

        if x < -0.5 {
            handleDirection(.left)
        } else if x > 0.5 {
            handleDirection(.right)
        }
    }

    private var lastThumbstickDirection: ControllerDirection?
    private let thumbstickDeadzone: Float = 0.5

    private func handleThumbstick(x: Float, y: Float) {
        var direction: ControllerDirection?

        // Determine direction with deadzone
        if abs(y) > abs(x) {
            if y > thumbstickDeadzone { direction = .up }
            else if y < -thumbstickDeadzone { direction = .down }
        } else {
            if x < -thumbstickDeadzone { direction = .left }
            else if x > thumbstickDeadzone { direction = .right }
        }

        // Only fire on direction change
        if direction != lastThumbstickDirection {
            lastThumbstickDirection = direction
            if let dir = direction {
                print("🎮 LEFT thumbstick direction: \(dir)")
                handleDirection(dir)
            }
        }
    }

    private func handleDirection(_ direction: ControllerDirection) {
        DispatchQueue.main.async {
            self.lastDirection = direction
            // Clear after a short delay to prevent stale values when views re-subscribe
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if self.lastDirection == direction {
                    self.lastDirection = nil
                }
            }
        }
    }

    private func handleButton(_ button: ControllerButton) {
        DispatchQueue.main.async {
            print("🎮 Button: \(button.rawValue)")
            self.lastButtonPress = button
            // Clear after a delay to prevent stale values when views re-subscribe
            // Use longer delay to ensure all subscribers have processed the event
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self.lastButtonPress == button {
                    self.lastButtonPress = nil
                }
            }
        }
    }
}

// MARK: - Convenience for SwiftUI

extension GameControllerManager {
    /// Human-readable controller name
    var controllerName: String {
        connectedController?.vendorName ?? "No Controller"
    }

    /// Battery percentage (0-100) if available
    var batteryPercentage: Int? {
        guard let battery = connectedController?.battery else { return nil }
        return Int(battery.batteryLevel * 100)
    }
}
