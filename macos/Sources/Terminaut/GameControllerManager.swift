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

    /// Is a controller currently connected?
    var isConnected: Bool { connectedController != nil }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Button Types

    enum ControllerButton: String {
        case a = "A"           // Confirm (Enter)
        case b = "B"           // Back (Escape)
        case x = "X"           // New session (N)
        case y = "Y"           // Sessions list (S)
        case leftBumper = "L"  // Previous tab
        case rightBumper = "R" // Next tab
        case start = "Start"   // Menu
        case select = "Select" // Options
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
                handleDirection(dir)
            }
        }
    }

    private func handleDirection(_ direction: ControllerDirection) {
        DispatchQueue.main.async {
            self.lastDirection = direction
        }
    }

    private func handleButton(_ button: ControllerButton) {
        DispatchQueue.main.async {
            self.lastButtonPress = button
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
