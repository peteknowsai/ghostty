import Foundation

/// Represents a Claude Code session with metadata parsed from JSONL files
struct ClaudeSession: Identifiable, Comparable {
    let id: String  // UUID from filename
    let filePath: URL
    let lastModified: Date
    let messageCount: Int
    let firstUserMessage: String?
    let fileSize: Int64

    /// Display name - truncated first message or session ID
    var displayName: String {
        if let msg = firstUserMessage, !msg.isEmpty {
            let truncated = msg.prefix(60)
            return truncated.count < msg.count ? "\(truncated)..." : String(truncated)
        }
        return "Session \(id.prefix(8))"
    }

    /// Relative time string
    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }

    /// File size formatted
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    static func < (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool {
        lhs.lastModified > rhs.lastModified  // Most recent first
    }
}

/// Reads and parses Claude Code session files
class SessionStore {
    static let shared = SessionStore()

    private let claudeProjectsPath: URL

    private init() {
        claudeProjectsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Get sessions for a project path
    func getSessions(for projectPath: String) -> [ClaudeSession] {
        let encodedPath = encodeProjectPath(projectPath)
        let projectDir = claudeProjectsPath.appendingPathComponent(encodedPath)

        guard FileManager.default.fileExists(atPath: projectDir.path) else {
            return []
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let sessions = contents
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { parseSessionFile($0) }
                .sorted()

            return sessions
        } catch {
            print("SessionStore: Error reading sessions: \(error)")
            return []
        }
    }

    /// Encode project path to Claude's directory naming format
    /// e.g., /Users/pete/Projects/foo -> -Users-pete-Projects-foo
    private func encodeProjectPath(_ path: String) -> String {
        // Expand ~ if present
        let expandedPath = (path as NSString).expandingTildeInPath
        // Replace / with -
        return expandedPath.replacingOccurrences(of: "/", with: "-")
    }

    /// Parse a session JSONL file to extract metadata
    private func parseSessionFile(_ url: URL) -> ClaudeSession? {
        let sessionId = url.deletingPathExtension().lastPathComponent

        // Skip directories (some sessions have companion directories)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let lastModified = attributes[.modificationDate] as? Date ?? Date.distantPast
            let fileSize = attributes[.size] as? Int64 ?? 0

            // Read first few lines to get message count and first user message
            let (messageCount, firstUserMessage) = parseSessionContent(url)

            return ClaudeSession(
                id: sessionId,
                filePath: url,
                lastModified: lastModified,
                messageCount: messageCount,
                firstUserMessage: firstUserMessage,
                fileSize: fileSize
            )
        } catch {
            print("SessionStore: Error parsing \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Parse session content to get message count and first user message
    private func parseSessionContent(_ url: URL) -> (Int, String?) {
        var messageCount = 0
        var firstUserMessage: String? = nil

        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return (0, nil)
        }
        defer { try? handle.close() }

        // Read up to 64KB to find first user message
        let data = handle.readData(ofLength: 65536)
        guard let content = String(data: data, encoding: .utf8) else {
            return (0, nil)
        }

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty else { continue }
            messageCount += 1

            // Try to parse as JSON and find first user message
            if firstUserMessage == nil,
               let jsonData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                // Claude Code JSONL format has "type" field
                if let type = json["type"] as? String {
                    if type == "user" {
                        // User message - extract text
                        if let message = json["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            firstUserMessage = cleanMessage(content)
                        } else if let content = json["content"] as? String {
                            firstUserMessage = cleanMessage(content)
                        }
                    }
                }
            }
        }

        // If we read the whole file (< 64KB), messageCount is accurate
        // Otherwise it's an approximation
        return (messageCount, firstUserMessage)
    }

    /// Clean up message text for display
    private func cleanMessage(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }
}
