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
    }

    private func handleControllerButton(_ button: GameControllerManager.ControllerButton) {
        // Global actions that work regardless of current view
        switch button {
        case .select:
            // Select = Return to launcher (like Cmd+L)
            returnToLauncher()
        case .leftBumper:
            // L = Previous tab
            previousSession()
        case .rightBumper:
            // R = Next tab
            nextSession()
        case .a:
            // A = Enter (when in session)
            if !showLauncher {
                simulateKey(keyCode: 36) // Return/Enter
            }
        case .b:
            // B = Escape (when in session)
            if !showLauncher {
                simulateKey(keyCode: 53) // Escape
            }
        default:
            // Other buttons are handled by the active view (LauncherView or SessionView)
            break
        }
    }

    /// Simulate a key press - sends directly to terminal surface
    private func simulateKey(keyCode: CGKeyCode) {
        // Get the current terminal surface view
        guard selectedSessionIndex < activeSessions.count,
              let surfaceView = activeSessions[selectedSessionIndex].surfaceView else {
            return
        }

        // Get the AppKit view from the SwiftUI wrapper
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            return
        }

        // Create NSEvent for key down
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: keyCode == 36 ? "\r" : "\u{1B}",  // Return or Escape
            charactersIgnoringModifiers: keyCode == 36 ? "\r" : "\u{1B}",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) {
            // Send to the first responder (should be terminal)
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
            characters: keyCode == 36 ? "\r" : "\u{1B}",
            charactersIgnoringModifiers: keyCode == 36 ? "\r" : "\u{1B}",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) {
            window.sendEvent(event)
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
        guard index >= 0, index < activeSessions.count else {
            returnToLauncher()
            return
        }

        let closedProject = activeSessions[index].project
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
