import SwiftUI
import AppKit

/// Modal view for picking a previous Claude session to resume
struct SessionPickerView: View {
    let project: Project
    let sessions: [ClaudeSession]
    let onSelect: (ClaudeSession?) -> Void  // nil = cancelled
    let onNewSession: () -> Void

    @State private var selectedIndex: Int = 0
    @State private var keyboardViewId: UUID = UUID()

    var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                headerView

                // Session list
                if sessions.isEmpty {
                    emptyStateView
                } else {
                    sessionListView
                }

                // Footer with controls
                footerView
            }
            .frame(maxWidth: 800, maxHeight: 600)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .background(SessionPickerKeyboardHandler { event in
            handleKeyEvent(event)
        }.id(keyboardViewId))
        .onAppear {
            keyboardViewId = UUID()
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Sessions")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Text(project.name)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.cyan)
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No previous sessions")
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.gray)

            Text("Press N to start a new session")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var sessionListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(
                            session: session,
                            isSelected: index == selectedIndex,
                            isMostRecent: index == 0
                        )
                        .id(index)
                        .onTapGesture {
                            selectedIndex = index
                            onSelect(session)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: selectedIndex) { newIndex in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private var footerView: some View {
        HStack(spacing: 32) {
            controlHint(key: "↑↓", action: "Navigate")
            controlHint(key: "Enter", action: "Resume")
            controlHint(key: "N", action: "New Session")
            controlHint(key: "Esc", action: "Cancel")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
    }

    private func controlHint(key: String, action: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.2))
                .cornerRadius(4)

            Text(action)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
        }
    }

    // MARK: - Keyboard Handling

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: // Up arrow
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return true

        case 125: // Down arrow
            if selectedIndex < sessions.count - 1 {
                selectedIndex += 1
            }
            return true

        case 36: // Enter
            if !sessions.isEmpty {
                onSelect(sessions[selectedIndex])
            }
            return true

        case 45: // N key
            onNewSession()
            return true

        case 53: // Escape
            onSelect(nil)
            return true

        default:
            return false
        }
    }
}

/// Row view for a single session
struct SessionRow: View {
    let session: ClaudeSession
    let isSelected: Bool
    let isMostRecent: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Circle()
                .fill(isSelected ? Color.cyan : Color.clear)
                .frame(width: 8, height: 8)

            // Session info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.displayName)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(isSelected ? .white : .gray)
                        .lineLimit(1)

                    if isMostRecent {
                        Text("LATEST")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 16) {
                    Text(session.relativeTime)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))

                    Text("\(session.messageCount) msgs")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))

                    Text(session.formattedSize)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                }
            }

            Spacer()

            // Session ID preview
            Text(session.id.prefix(8))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.cyan.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}

/// Keyboard handler for session picker
struct SessionPickerKeyboardHandler: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> SessionPickerKeyView {
        let view = SessionPickerKeyView()
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: SessionPickerKeyView, context: Context) {
        nsView.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    class SessionPickerKeyView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if let handler = onKeyDown, handler(event) {
                return
            }
            super.keyDown(with: event)
        }
    }
}

#Preview {
    SessionPickerView(
        project: Project(name: "test-project", path: "/Users/pete/Projects/test"),
        sessions: [
            ClaudeSession(
                id: "abc123-def456",
                filePath: URL(fileURLWithPath: "/tmp/test.jsonl"),
                lastModified: Date().addingTimeInterval(-3600),
                messageCount: 42,
                firstUserMessage: "Help me implement a new feature for user authentication",
                fileSize: 125000
            ),
            ClaudeSession(
                id: "xyz789-uvw012",
                filePath: URL(fileURLWithPath: "/tmp/test2.jsonl"),
                lastModified: Date().addingTimeInterval(-86400),
                messageCount: 15,
                firstUserMessage: "Fix the bug in the login flow",
                fileSize: 45000
            )
        ],
        onSelect: { _ in },
        onNewSession: { }
    )
    .frame(width: 1200, height: 800)
}
