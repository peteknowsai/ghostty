import Foundation
import Combine

/// Represents a project that can be launched in Terminaut
struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var icon: String?
    var lastOpened: Date?
    var hasActivity: Bool = false

    init(id: UUID = UUID(), name: String, path: String, icon: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon
        self.lastOpened = nil
    }
}

/// Manages the list of projects and persists them to disk
class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published var projects: [Project] = []
    @Published var selectedIndex: Int = 0

    private let projectsURL: URL

    private init() {
        // Store projects in ~/.terminaut/projects.json
        let home = FileManager.default.homeDirectoryForCurrentUser
        let terminautDir = home.appendingPathComponent(".terminaut")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: terminautDir, withIntermediateDirectories: true)

        projectsURL = terminautDir.appendingPathComponent("projects.json")
        loadProjects()
    }

    func loadProjects() {
        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            // Create default projects for common locations
            scanForProjects()
            return
        }

        do {
            let data = try Data(contentsOf: projectsURL)
            projects = try JSONDecoder().decode([Project].self, from: data)

            // If no projects have lastOpened, try to recover from Claude session dirs
            let hasAnyLastOpened = projects.contains { $0.lastOpened != nil }
            if !hasAnyLastOpened && !projects.isEmpty {
                recoverLastOpenedFromClaudeSessions()
            }
        } catch {
            print("Failed to load projects: \(error)")
            scanForProjects()
        }
    }

    /// Recover lastOpened dates from Claude Code session directory timestamps
    private func recoverLastOpenedFromClaudeSessions() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeProjectsDir = home.appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: claudeProjectsDir.path) else { return }

        var updated = false

        for i in 0..<projects.count {
            let project = projects[i]
            // Claude encodes paths like: /Users/pete/Projects/foo -> -Users-pete-Projects-foo
            let encodedPath = project.path.replacingOccurrences(of: "/", with: "-")
            let sessionDir = claudeProjectsDir.appendingPathComponent(encodedPath)

            if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionDir.path),
               let modDate = attrs[.modificationDate] as? Date {
                projects[i].lastOpened = modDate
                updated = true
            }
        }

        if updated {
            // Re-sort by lastOpened
            projects.sort { p1, p2 in
                if let d1 = p1.lastOpened, let d2 = p2.lastOpened {
                    return d1 > d2
                } else if p1.lastOpened != nil {
                    return true
                } else if p2.lastOpened != nil {
                    return false
                } else {
                    return p1.name.localizedCaseInsensitiveCompare(p2.name) == .orderedAscending
                }
            }
            saveProjects()
            print("Recovered lastOpened dates from Claude session directories")
        }
    }

    func saveProjects() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(projects)
            try data.write(to: projectsURL)
        } catch {
            print("Failed to save projects: \(error)")
        }
    }

    /// Scan common directories for projects (merges with existing, preserves metadata)
    func scanForProjects() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectDirs = [
            home.appendingPathComponent("Projects"),
            home.appendingPathComponent("Developer"),
            home.appendingPathComponent("Code"),
        ]

        // Build a map of existing projects by path for quick lookup
        var existingByPath: [String: Project] = [:]
        for project in projects {
            existingByPath[project.path] = project
        }

        var mergedProjects: [Project] = []
        var seenPaths: Set<String> = []

        for dir in projectDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                   isDir.boolValue {
                    // Check if it's a git repo or has common project files
                    let gitDir = url.appendingPathComponent(".git")
                    let packageJson = url.appendingPathComponent("package.json")
                    let cargoToml = url.appendingPathComponent("Cargo.toml")
                    let gemfile = url.appendingPathComponent("Gemfile")
                    let buildZig = url.appendingPathComponent("build.zig")
                    let claudeMd = url.appendingPathComponent("CLAUDE.md")

                    let isProject = [gitDir, packageJson, cargoToml, gemfile, buildZig, claudeMd].contains {
                        FileManager.default.fileExists(atPath: $0.path)
                    }

                    if isProject {
                        let path = url.path
                        if !seenPaths.contains(path) {
                            seenPaths.insert(path)
                            // Preserve existing project if we have it (keeps id, lastOpened, etc.)
                            if let existing = existingByPath[path] {
                                mergedProjects.append(existing)
                            } else {
                                mergedProjects.append(Project(
                                    name: url.lastPathComponent,
                                    path: path
                                ))
                            }
                        }
                    }
                }
            }
        }

        // Also keep any manually-added projects that weren't in scanned dirs
        for project in projects {
            if !seenPaths.contains(project.path) {
                // Check if path still exists
                if FileManager.default.fileExists(atPath: project.path) {
                    mergedProjects.append(project)
                }
            }
        }

        // Sort: recently opened first, then by name
        mergedProjects.sort { p1, p2 in
            if let d1 = p1.lastOpened, let d2 = p2.lastOpened {
                return d1 > d2  // Most recent first
            } else if p1.lastOpened != nil {
                return true  // Projects with lastOpened come first
            } else if p2.lastOpened != nil {
                return false
            } else {
                return p1.name.localizedCaseInsensitiveCompare(p2.name) == .orderedAscending
            }
        }

        projects = mergedProjects
        saveProjects()
    }

    func addProject(name: String, path: String) {
        let project = Project(name: name, path: path)
        projects.append(project)
        saveProjects()
    }

    func removeProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        projects.remove(at: index)
        if selectedIndex >= projects.count {
            selectedIndex = max(0, projects.count - 1)
        }
        saveProjects()
    }

    func markOpened(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].lastOpened = Date()
            saveProjects()
        }
    }

    // Navigation
    func moveSelection(by delta: Int) {
        guard !projects.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + projects.count) % projects.count
    }

    /// Grid-aware vertical navigation that stays in the same column
    func moveVertical(by rowDelta: Int, columnCount: Int) {
        guard !projects.isEmpty else { return }

        let currentRow = selectedIndex / columnCount
        let currentCol = selectedIndex % columnCount
        let totalRows = (projects.count + columnCount - 1) / columnCount

        var targetRow = currentRow + rowDelta

        if targetRow < 0 {
            // Wrap to bottom - find last row that has this column
            targetRow = totalRows - 1
            var targetIndex = targetRow * columnCount + currentCol
            while targetIndex >= projects.count && targetRow > 0 {
                targetRow -= 1
                targetIndex = targetRow * columnCount + currentCol
            }
            selectedIndex = min(targetIndex, projects.count - 1)
        } else if targetRow >= totalRows {
            // Wrap to top
            selectedIndex = currentCol
        } else {
            // Normal move
            let targetIndex = targetRow * columnCount + currentCol
            if targetIndex < projects.count {
                selectedIndex = targetIndex
            } else {
                // Target doesn't exist (partial row), wrap to top of column
                selectedIndex = currentCol
            }
        }
    }

    /// Horizontal navigation with row wrapping
    func moveHorizontal(by colDelta: Int, columnCount: Int) {
        guard !projects.isEmpty else { return }

        let newIndex = selectedIndex + colDelta

        if newIndex < 0 {
            // Wrap to end of previous row or last item
            selectedIndex = max(0, selectedIndex - 1)
        } else if newIndex >= projects.count {
            // At the end, wrap to start
            selectedIndex = 0
        } else {
            selectedIndex = newIndex
        }
    }

    var selectedProject: Project? {
        guard selectedIndex >= 0, selectedIndex < projects.count else { return nil }
        return projects[selectedIndex]
    }
}
