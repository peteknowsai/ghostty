import AppKit
import SwiftUI
import GhosttyKit
import Combine

/// Coordinates Terminaut state - launcher vs session, active project, etc.
/// No longer manages windows - that's handled by SwiftUI in TerminautRootView
class TerminautCoordinator: ObservableObject {
    static let shared = TerminautCoordinator()

    /// True when showing the launcher, false when in a session
    @Published var showLauncher: Bool = true

    /// Controller manager for game controller input
    let controllerManager = GameControllerManager.shared
    private var controllerCancellables = Set<AnyCancellable>()

    /// The currently active project (when in session mode)
    @Published var activeProject: Project?

    /// Active sessions for tab management
    @Published var activeSessions: [Session] = []

    /// Currently selected session index (for tabs)
    @Published var selectedSessionIndex: Int = 0

    /// Active project IDs in activation order (first tab open = first in array)
    @Published var activeProjectIdsOrdered: [UUID] = []

    /// Reference to ghostty app for creating surfaces
    weak var ghosttyApp: Ghostty.App?

    /// Session struct that holds the project and its terminal surface
    struct Session: Identifiable {
        let id = UUID()
        let project: Project
        var surfaceView: Ghostty.SurfaceView?
        var hasActivity: Bool = false

        init(project: Project, surfaceView: Ghostty.SurfaceView? = nil) {
            self.project = project
            self.surfaceView = surfaceView
        }
    }

    private init() {
        setupMenuItems()
        setupControllerBindings()
        controllerManager.start()
    }

    // MARK: - Controller Handling (Global)

    private func setupControllerBindings() {
        // Handle button presses globally (works in both launcher and session)
        controllerManager.$lastButtonPress
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] button in
                self?.handleControllerButton(button)
            }
            .store(in: &controllerCancellables)

        // Handle D-pad direction for vim mode navigation
        controllerManager.$lastDirection
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] direction in
                self?.handleControllerDirection(direction)
            }
            .store(in: &controllerCancellables)
    }

    private func handleControllerButton(_ button: GameControllerManager.ControllerButton) {
        let vimMode = controllerManager.vimModeActive

        // Global actions - always active regardless of vim mode
        switch button {
        case .rightPaddle:
            // Right paddle = Escape (always)
            if !showLauncher {
                simulateKey(keyCode: 53)
            }
            return
        case .leftPaddle:
            // Left paddle = Shift-Tab (always)
            if !showLauncher {
                simulateShiftTab()
            }
            return
        case .rightStickClick:
            // R3 = Toggle select mode (handled in GameControllerManager)
            // Don't send any key - just used for mode toggle
            return
        case .leftStickClick:
            // L3 = Insert mode (i) - get back to typing
            if !showLauncher {
                simulateText("i")
            }
            return
        case .select:
            // Select = Return to launcher (like Cmd+L)
            returnToLauncher()
            return
        case .leftBumper:
            // L bumper = Previous tab (always)
            print("🎮 L bumper -> previousSession (sessions: \(activeSessions.count))")
            previousSession()
            return
        case .rightBumper:
            // R bumper = Next tab (always)
            print("🎮 R bumper -> nextSession (sessions: \(activeSessions.count))")
            nextSession()
            return
        default:
            break
        }

        // Session button mappings (no vim mode gating - user knows when they're in vim)
        if !showLauncher {
            switch button {
            case .a:
                if controllerManager.selectModeActive {
                    simulateCopy() // Cmd+C in select mode
                    // Exit select mode after copying
                    DispatchQueue.main.async {
                        self.controllerManager.selectModeActive = false
                        print("🎮 Select mode: OFF (copied)")
                    }
                } else {
                    simulateKey(keyCode: 36) // Enter
                }
            case .b:
                simulateKey(keyCode: 53) // Escape
            case .x:
                simulateText("dd") // Delete line (vim)
            case .y:
                simulateText("yy") // Yank line (vim)
            default:
                break
            }
        }
    }

    /// Simulate Cmd+C for copying
    private func simulateCopy() {
        guard let window = NSApp.keyWindow else { return }

        // Create Cmd+C key event
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8 // C key code
        ) {
            window.sendEvent(event)
        }

        if let event = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ) {
            window.sendEvent(event)
        }
    }

    private func handleControllerDirection(_ direction: GameControllerManager.ControllerDirection) {
        // Don't handle directions in launcher (LauncherView handles its own navigation)
        guard !showLauncher else { return }

        // Always send arrow keys for menu/list navigation
        switch direction {
        case .up:
            simulateKey(keyCode: 126) // Up arrow
        case .down:
            simulateKey(keyCode: 125) // Down arrow
        case .left:
            simulateKey(keyCode: 123) // Left arrow
        case .right:
            simulateKey(keyCode: 124) // Right arrow
        }
    }

    private func simulateShiftTab() {
        guard let window = NSApp.keyWindow else { return }

        // Create Shift+Tab key event
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{19}", // Shift-Tab character
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48 // Tab key code
        ) {
            window.sendEvent(event)
        }

        if let event = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{19}",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ) {
            window.sendEvent(event)
        }
    }

    /// Simulate a key press - sends directly to terminal surface
    private func simulateKey(keyCode: CGKeyCode) {
        guard let window = NSApp.keyWindow else { return }

        let characters = characterForKeyCode(keyCode)

        // Create NSEvent for key down
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) {
            window.sendEvent(event)
        }

        // Create NSEvent for key up
        if let event = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) {
            window.sendEvent(event)
        }
    }

    /// Get the character string for a key code
    private func characterForKeyCode(_ keyCode: CGKeyCode) -> String {
        switch keyCode {
        case 36: return "\r"           // Return
        case 53: return "\u{1B}"       // Escape
        case 123: return "\u{F702}"    // Left arrow
        case 124: return "\u{F703}"    // Right arrow
        case 125: return "\u{F701}"    // Down arrow
        case 126: return "\u{F700}"    // Up arrow
        default: return ""
        }
    }

    /// Simulate typing a string of text
    private func simulateText(_ text: String) {
        guard let window = NSApp.keyWindow else { return }

        for char in text {
            let charStr = String(char)

            // Create key down event
            if let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: charStr,
                charactersIgnoringModifiers: charStr,
                isARepeat: false,
                keyCode: keyCodeForCharacter(char)
            ) {
                window.sendEvent(event)
            }

            // Create key up event
            if let event = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: charStr,
                charactersIgnoringModifiers: charStr,
                isARepeat: false,
                keyCode: keyCodeForCharacter(char)
            ) {
                window.sendEvent(event)
            }
        }
    }

    /// Get the key code for a character (simplified mapping)
    private func keyCodeForCharacter(_ char: Character) -> UInt16 {
        switch char {
        case "d": return 2
        case "a": return 0
        case "s": return 1
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "t": return 17
        case "y": return 16
        case "u": return 32
        case "i": return 34
        case "o": return 31
        case "p": return 35
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "n": return 45
        case "m": return 46
        default: return 0
        }
    }

    // MARK: - Navigation

    /// Launch modes for opening a project
    enum LaunchMode {
        case continueSession      // claude -c (default)
        case freshSession         // claude (new session)
        case resumeSession(String) // claude --resume <session-id>
    }

    /// Launch a project - transitions from launcher to session
    func launchProject(_ project: Project, mode: LaunchMode = .continueSession) {
        // Mark project as opened
        ProjectStore.shared.markOpened(project)

        // Check if already have a session for this project
        if let existingIndex = activeSessions.firstIndex(where: { $0.project.id == project.id }) {
            // Switch to existing session
            selectedSessionIndex = existingIndex
            activeProject = project
        } else {
            // Create new session with SurfaceView
            var surfaceView: Ghostty.SurfaceView? = nil

            if let ghostty = ghosttyApp, let app = ghostty.app {
                var config = Ghostty.SurfaceConfiguration()
                config.workingDirectory = project.path
                // Claude Code has slow startup for non-Apple terminals - this workaround fixes it
                config.environmentVariables["TERM_PROGRAM"] = "Apple_Terminal"

                // Set command based on launch mode
                switch mode {
                case .continueSession:
                    config.initialInput = "exec claude -c\n"
                case .freshSession:
                    config.initialInput = "exec claude\n"
                case .resumeSession(let sessionId):
                    config.initialInput = "exec claude --resume \(sessionId)\n"
                }

                surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
            }

            let session = Session(project: project, surfaceView: surfaceView)
            activeSessions.append(session)
            selectedSessionIndex = activeSessions.count - 1
            activeProject = project

            // Track activation order for launcher display
            if !activeProjectIdsOrdered.contains(project.id) {
                activeProjectIdsOrdered.append(project.id)
            }
        }

        showLauncher = false
    }

    /// Launch project with a fresh session (no -c flag)
    func launchFreshSession(_ project: Project) {
        launchProject(project, mode: .freshSession)
    }

    /// Resume a specific Claude session by ID
    func resumeSession(_ project: Project, sessionId: String) {
        launchProject(project, mode: .resumeSession(sessionId))
    }

    /// Return to launcher from session
    func returnToLauncher() {
        showLauncher = true
        // Keep activeProject and sessions so we can return
    }

    /// Close current session and return to launcher
    func closeCurrentSession() {
        closeSession(at: selectedSessionIndex)
    }

    /// Close session at specific index - always returns to launcher
    func closeSession(at index: Int) {
        print("🔴 closeSession called: index=\(index), totalSessions=\(activeSessions.count)")
        guard index >= 0, index < activeSessions.count else {
            print("🔴 closeSession: invalid index, returning to launcher")
            returnToLauncher()
            return
        }

        let closedProject = activeSessions[index].project
        print("🔴 Removing session for: \(closedProject.name)")
        activeSessions.remove(at: index)

        // Remove from activation order when session closes
        activeProjectIdsOrdered.removeAll { $0 == closedProject.id }

        // Always return to launcher when closing a session
        if activeSessions.isEmpty {
            activeProject = nil
        } else {
            // Adjust selection for when user returns from launcher
            if selectedSessionIndex >= activeSessions.count {
                selectedSessionIndex = activeSessions.count - 1
            } else if index < selectedSessionIndex {
                selectedSessionIndex -= 1
            }
            activeProject = activeSessions[selectedSessionIndex].project
        }
        showLauncher = true
    }

    /// Switch to a specific session tab
    func switchToSession(at index: Int) {
        guard index >= 0, index < activeSessions.count else { return }
        selectedSessionIndex = index
        activeProject = activeSessions[index].project
        showLauncher = false
    }

    /// Teleport to an existing Claude Code session (creates new tab)
    func teleportToSession(_ sessionId: String) {
        guard let project = activeProject,
              let ghostty = ghosttyApp,
              let app = ghostty.app else { return }

        // Create surface with teleport command instead of normal claude startup
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = project.path
        config.environmentVariables["TERM_PROGRAM"] = "Apple_Terminal"
        config.initialInput = "exec claude --teleport \(sessionId)\n"

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        let session = Session(project: project, surfaceView: surfaceView)
        activeSessions.append(session)
        selectedSessionIndex = activeSessions.count - 1
    }

    /// Switch to next session tab
    func nextSession() {
        guard !activeSessions.isEmpty else { return }
        switchToSession(at: (selectedSessionIndex + 1) % activeSessions.count)
    }

    /// Switch to previous session tab
    func previousSession() {
        guard !activeSessions.isEmpty else { return }
        let newIndex = selectedSessionIndex - 1
        switchToSession(at: newIndex < 0 ? activeSessions.count - 1 : newIndex)
    }

    // MARK: - Menu Items

    private func setupMenuItems() {
        DispatchQueue.main.async {
            self.addTerminautMenu()
        }
    }

    private func addTerminautMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Check if we already added the menu
        if mainMenu.items.contains(where: { $0.title == "Terminaut" }) {
            return
        }

        let terminautMenu = NSMenu(title: "Terminaut")

        // Show Launcher - Cmd+L
        let launcherItem = NSMenuItem(
            title: "Show Launcher",
            action: #selector(showLauncherAction),
            keyEquivalent: "l"
        )
        launcherItem.keyEquivalentModifierMask = .command
        launcherItem.target = self
        terminautMenu.addItem(launcherItem)

        // Close Session - Cmd+W (when in session)
        let closeItem = NSMenuItem(
            title: "Close Session",
            action: #selector(closeSessionAction),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        closeItem.target = self
        terminautMenu.addItem(closeItem)

        terminautMenu.addItem(NSMenuItem.separator())

        // Next Tab - Ctrl+Tab
        let nextTabItem = NSMenuItem(
            title: "Next Session",
            action: #selector(nextSessionAction),
            keyEquivalent: "\t"
        )
        nextTabItem.keyEquivalentModifierMask = .control
        nextTabItem.target = self
        terminautMenu.addItem(nextTabItem)

        // Previous Tab - Ctrl+Shift+Tab
        let prevTabItem = NSMenuItem(
            title: "Previous Session",
            action: #selector(previousSessionAction),
            keyEquivalent: "\t"
        )
        prevTabItem.keyEquivalentModifierMask = [.control, .shift]
        prevTabItem.target = self
        terminautMenu.addItem(prevTabItem)

        let terminautMenuItem = NSMenuItem(title: "Terminaut", action: nil, keyEquivalent: "")
        terminautMenuItem.submenu = terminautMenu

        // Insert after File menu
        if mainMenu.items.count > 1 {
            mainMenu.insertItem(terminautMenuItem, at: 2)
        } else {
            mainMenu.addItem(terminautMenuItem)
        }
    }

    @objc private func showLauncherAction() {
        returnToLauncher()
    }

    @objc private func closeSessionAction() {
        closeCurrentSession()
    }

    @objc private func nextSessionAction() {
        nextSession()
    }

    @objc private func previousSessionAction() {
        previousSession()
    }
}

// MARK: - Window Setup

extension TerminautCoordinator {
    /// Creates the single fullscreen window for Terminaut
    /// Call this from AppDelegate on launch
    func createMainWindow(ghostty: Ghostty.App) -> NSWindow {
        // Store reference for creating surfaces later
        self.ghosttyApp = ghostty

        let rootView = TerminautRootView(coordinator: self)
            .environmentObject(ghostty)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Terminaut"

        // Enter fullscreen
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        return window
    }
}
