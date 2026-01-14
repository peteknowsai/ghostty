import SwiftUI
import AppKit
import GhosttyKit

/// Root view for Terminaut - switches between launcher and session
/// Lives in a single fullscreen window, no window management needed
struct TerminautRootView: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject var coordinator: TerminautCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if coordinator.showLauncher {
                LauncherView(
                    projectStore: ProjectStore.shared,
                    activeProjectIdsOrdered: coordinator.activeProjectIdsOrdered,
                    onSelect: { project in
                        coordinator.launchProject(project)
                    },
                    onFreshSession: { project in
                        coordinator.launchFreshSession(project)
                    },
                    onResumeSession: { project, sessionId in
                        coordinator.resumeSession(project, sessionId: sessionId)
                    }
                )
                .transition(.opacity)
            } else if let project = coordinator.activeProject {
                TerminautSessionView(
                    coordinator: coordinator,
                    project: project,
                    onReturnToLauncher: {
                        coordinator.returnToLauncher()
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.showLauncher)
    }
}

/// Session view with embedded terminal and control panel
struct TerminautSessionView: View {
    @ObservedObject var coordinator: TerminautCoordinator
    let project: Project
    let onReturnToLauncher: () -> Void

    @EnvironmentObject private var ghostty: Ghostty.App
    @StateObject private var stateWatcher = SessionStateWatcher()

    // Control panel takes 25% of width
    private let controlPanelRatio: CGFloat = 0.25

    /// Get current session's surface view
    private var currentSurfaceView: Ghostty.SurfaceView? {
        guard coordinator.selectedSessionIndex < coordinator.activeSessions.count else { return nil }
        return coordinator.activeSessions[coordinator.selectedSessionIndex].surfaceView
    }

    var body: some View {
        let closeSurfacePublisher = NotificationCenter.default.publisher(for: Notification.Name("com.mitchellh.ghostty.closeSurface"))

        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left 75%: Tab bar + Terminal
                VStack(spacing: 0) {
                    // Tab bar (only show if multiple sessions)
                    if coordinator.activeSessions.count > 1 {
                        TabBarView(
                            sessions: coordinator.activeSessions,
                            selectedIndex: coordinator.selectedSessionIndex,
                            onSelect: { index in
                                coordinator.switchToSession(at: index)
                            },
                            onClose: { index in
                                coordinator.closeSession(at: index)
                            }
                        )
                    }

                    // Terminal with copy indicator overlay
                    terminalPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .copyIndicator()
                }
                .frame(width: geometry.size.width * 0.75)

                // Right 25%: Control Panel
                ControlPanelView(
                    project: project,
                    stateWatcher: stateWatcher,
                    onReturnToLauncher: onReturnToLauncher,
                    onTeleport: { sessionId in
                        coordinator.teleportToSession(sessionId)
                    }
                )
                .frame(width: geometry.size.width * 0.25)
            }
        }
        .onReceive(closeSurfacePublisher) { notification in
            // When a surface closes (e.g., user types "exit"), close that session
            guard let surface = notification.object as? Ghostty.SurfaceView else { return }
            let processAlive = notification.userInfo?["process_alive"] as? Bool ?? true

            // Only auto-close if the process exited (not alive)
            if !processAlive {
                // Find which session this surface belongs to and close it
                if let index = coordinator.activeSessions.firstIndex(where: { $0.surfaceView === surface }) {
                    coordinator.closeSession(at: index)
                }
            }
        }
        .onAppear {
            // Start watching for state files matching this project
            stateWatcher.watchProject(path: project.path)
        }
        .onChange(of: project.path) { newPath in
            // Update watcher if project changes
            stateWatcher.watchProject(path: newPath)
        }
    }

    /// Current session ID for view identity
    private var currentSessionId: UUID? {
        guard coordinator.selectedSessionIndex < coordinator.activeSessions.count else { return nil }
        return coordinator.activeSessions[coordinator.selectedSessionIndex].id
    }

    /// Focus the terminal surface so user can type immediately
    private func focusTerminal(_ surfaceView: Ghostty.SurfaceView) {
        // Small delay to ensure view is in hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
    }

    @ViewBuilder
    private var terminalPane: some View {
        if let surfaceView = currentSurfaceView {
            // Use stored surface from session - .id() forces SwiftUI to swap views when session changes
            Ghostty.SurfaceWrapper(surfaceView: surfaceView)
                .id(currentSessionId)
                .onAppear {
                    focusTerminal(surfaceView)
                }
                .onChange(of: currentSessionId) { _ in
                    // Re-focus terminal when switching tabs
                    if let sv = currentSurfaceView {
                        focusTerminal(sv)
                    }
                }
        } else if let app = ghostty.app {
            // Fallback: create new surface (shouldn't happen normally)
            TerminalSurface(
                app: app,
                workingDirectory: project.path
            )
        } else {
            // Fallback if ghostty not ready
            Color.black
                .overlay(
                    Text("Initializing terminal...")
                        .foregroundColor(.gray)
                )
        }
    }
}

/// Wraps Ghostty.SurfaceView with project-specific configuration
struct TerminalSurface: View {
    let app: ghostty_app_t
    let workingDirectory: String

    @StateObject private var surfaceView: Ghostty.SurfaceView

    init(app: ghostty_app_t, workingDirectory: String) {
        self.app = app
        self.workingDirectory = workingDirectory

        // Create surface configuration
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workingDirectory
        // Claude Code has slow startup for non-Apple terminals - this workaround fixes it
        config.environmentVariables["TERM_PROGRAM"] = "Apple_Terminal"
        config.initialInput = "exec claude -c\n"

        // Initialize surface view with config
        _surfaceView = StateObject(wrappedValue: Ghostty.SurfaceView(app, baseConfig: config))
    }

    var body: some View {
        Ghostty.SurfaceWrapper(surfaceView: surfaceView)
    }
}

/// Control panel with all interactive panels
struct ControlPanelView: View {
    let project: Project
    @ObservedObject var stateWatcher: SessionStateWatcher
    let onReturnToLauncher: () -> Void
    let onTeleport: (String) -> Void  // sessionId -> teleport to that session

    @State private var selectedPanel: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Project header
            projectHeader

            Divider()
                .background(Color.white.opacity(0.2))

            // Scrollable panels
            ScrollView {
                VStack(spacing: 12) {
                    // Context panel (session context window)
                    ContextPanel(state: stateWatcher.state)

                    // Usage/Quota panel (weekly usage)
                    QuotaPanel(state: stateWatcher.state)

                    // Todos panel
                    TodosPanel(state: stateWatcher.state)

                    // Git panel
                    GitPanel(state: stateWatcher.state)

                    // Tasks panel (background tasks with teleport)
                    TasksPanel(
                        state: stateWatcher.state,
                        onOpenWeb: { task in
                            if let url = URL(string: task.webUrl) {
                                NSWorkspace.shared.open(url)
                            }
                        },
                        onTeleport: { task in
                            onTeleport(task.sessionId)
                        },
                        onArchive: { task in
                            TaskArchiveManager.shared.archiveTask(sessionId: task.sessionId)
                        }
                    )
                }
                .padding(12)
            }

            Divider()
                .background(Color.white.opacity(0.2))

            // Footer with controls
            controlsFooter
        }
        .background(Color.black.opacity(0.95))
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version).\(build)"
    }

    private var projectHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.name)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)

                    Text(appVersion)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundColor(.orange)
                }

                Text(project.path)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Back to launcher button
            Button {
                onReturnToLauncher()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .help("Return to Launcher (Cmd+L)")
        }
        .padding(16)
    }

    private var controlsFooter: some View {
        HStack(spacing: 24) {
            controlHint(key: "D-pad", action: "Navigate")
            controlHint(key: "A", action: "Select")
            controlHint(key: "B", action: "Back")
            controlHint(key: "Start", action: "Launcher")
        }
        .font(.system(size: 16, design: .monospaced))
        .foregroundColor(.gray)
        .padding(16)
    }

    private func controlHint(key: String, action: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.1))
                .cornerRadius(4)
            Text(action)
        }
    }
}

// MARK: - Panel Components

struct ContextPanel: View {
    let state: SessionState

    var body: some View {
        HStack(spacing: 12) {
            Text("CONTEXT")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(contextColor)
                        .frame(width: geo.size.width * contextPercent / 100)
                }
            }
            .frame(height: 20)

            // Percentage
            Text("\(Int(contextPercent))%")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(contextColor)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(panelBackground)
    }

    private var contextPercent: Double {
        if let ctx = state.context, let used = ctx.usedPercent {
            return Double(used)
        }
        return state.contextPercent ?? 0
    }

    private var contextColor: Color {
        if contextPercent > 80 { return .red }
        if contextPercent > 60 { return .orange }
        return .green
    }
}

struct QuotaPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("USAGE")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.gray)

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))

                        RoundedRectangle(cornerRadius: 4)
                            .fill(quotaColor)
                            .frame(width: geo.size.width * quotaPercent / 100)
                    }
                }
                .frame(height: 20)

                // Percentage
                Text("\(Int(quotaPercent))%")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(quotaColor)
                    .frame(width: 60, alignment: .trailing)
            }

            // Reset time
            HStack {
                Spacer()
                Text("Resets \(resetTimeString)")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(panelBackground)
    }

    private var quotaPercent: Double {
        return state.quotaPercent ?? 0
    }

    private var quotaColor: Color {
        if quotaPercent > 80 { return .red }
        if quotaPercent > 50 { return .orange }
        return .green
    }

    private var resetTimeString: String {
        // Resets Monday at midnight PT
        return "Mon 12:00 AM PT"
    }
}

struct TasksPanel: View {
    let state: SessionState
    let onOpenWeb: (SessionState.BackgroundTask) -> Void
    let onTeleport: (SessionState.BackgroundTask) -> Void
    let onArchive: (SessionState.BackgroundTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("TASKS")

            if let tasks = state.backgroundTasks, !tasks.isEmpty {
                ForEach(tasks) { task in
                    TaskRow(task: task, onOpenWeb: onOpenWeb, onTeleport: onTeleport, onArchive: onArchive)
                }
            } else {
                Text("No background tasks")
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .background(panelBackground)
    }
}

struct TaskRow: View {
    let task: SessionState.BackgroundTask
    let onOpenWeb: (SessionState.BackgroundTask) -> Void
    let onTeleport: (SessionState.BackgroundTask) -> Void
    let onArchive: (SessionState.BackgroundTask) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(task.description)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // Action buttons (aligned to top)
            HStack(spacing: 8) {
                // Web button
                Button { onOpenWeb(task) } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 18, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)

                // Teleport button
                Button { onTeleport(task) } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 18, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundColor(.green)

                // Archive button
                Button { onArchive(task) } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 18, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Preview

#Preview {
    let coordinator = TerminautCoordinator.shared
    coordinator.showLauncher = false
    coordinator.activeProject = Project(name: "terminaut-ghostty", path: "/Users/pete/Projects/terminaut-ghostty")

    return TerminautRootView(coordinator: coordinator)
        .frame(width: 1600, height: 1000)
        .environmentObject(Ghostty.App())
}
