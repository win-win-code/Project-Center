import AppKit

private struct ProjectDefinition: Decodable {
    let name: String
    let path: String
    let pushRecipe: String
    let buildRecipe: String
    let buildLabel: String
    let artifactPaths: [String]
}

private struct GitSnapshot {
    let isRepository: Bool
    let branch: String
    let isDetached: Bool
    let changedFiles: Int
    let hasCommit: Bool
    let hasOrigin: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let version: String
    let error: String?
}

private struct CommandResult {
    let command: String
    let workingDirectory: String
    let output: String
    let exitCode: Int32?
    let duration: TimeInterval
    let launchError: String?

    var succeeded: Bool {
        exitCode == 0 && launchError == nil
    }
}

private enum OperationKind: Equatable {
    case push
    case build
    case pushAndBuild

    var title: String {
        switch self {
        case .push: return "Push"
        case .build: return "Build"
        case .pushAndBuild: return "Push + Build"
        }
    }
}

private final class ProjectCard {
    let project: ProjectDefinition
    let container: NSBox
    let titleLabel: NSTextField
    let gitLabel: NSTextField
    let lastOperationLabel: NSTextField
    let pushButton: NSButton
    let buildButton: NSButton
    let pushAndBuildButton: NSButton
    let launchButton: NSButton
    let revealArtifactButton: NSButton
    var snapshot: GitSnapshot?
    var latestArtifact: URL?

    init(
        project: ProjectDefinition,
        container: NSBox,
        titleLabel: NSTextField,
        gitLabel: NSTextField,
        lastOperationLabel: NSTextField,
        pushButton: NSButton,
        buildButton: NSButton,
        pushAndBuildButton: NSButton,
        launchButton: NSButton,
        revealArtifactButton: NSButton
    ) {
        self.project = project
        self.container = container
        self.titleLabel = titleLabel
        self.gitLabel = gitLabel
        self.lastOperationLabel = lastOperationLabel
        self.pushButton = pushButton
        self.buildButton = buildButton
        self.pushAndBuildButton = pushAndBuildButton
        self.launchButton = launchButton
        self.revealArtifactButton = revealArtifactButton
    }
}

private final class CommandRunner {
    private let environment: [String: String]

    init() {
        var values = ProcessInfo.processInfo.environment
        let requiredPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = values["PATH"], !existing.isEmpty {
            values["PATH"] = "\(requiredPath):\(existing)"
        } else {
            values["PATH"] = requiredPath
        }
        environment = values
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL
    ) -> CommandResult {
        let startedAt = Date()
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let command = ([executable] + arguments).map(Self.shellDisplay).joined(separator: " ")

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForReading.close()
            return CommandResult(
                command: command,
                workingDirectory: workingDirectory.path,
                output: "",
                exitCode: nil,
                duration: Date().timeIntervalSince(startedAt),
                launchError: error.localizedDescription
            )
        }

        // Drain the pipe before waiting for termination. This preserves the final
        // stdout/stderr bytes even when a process exits immediately and avoids a
        // full-pipe deadlock for verbose builds.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? outputPipe.fileHandleForReading.close()

        return CommandResult(
            command: command,
            workingDirectory: workingDirectory.path,
            output: String(decoding: data, as: UTF8.self),
            exitCode: process.terminationStatus,
            duration: Date().timeIntervalSince(startedAt),
            launchError: nil
        )
    }

    private static func shellDisplay(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-=:"))
        if !value.isEmpty && value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let commandRunner = CommandRunner()
    private let operationQueue = DispatchQueue(label: "com.ruslan.project-center.operations", qos: .userInitiated)
    private let fileManager = FileManager.default

    private var projects: [ProjectDefinition] = []
    private var cards: [ProjectCard] = []
    private var configURL: URL?
    private var justfileURL: URL!
    private var projectsRootURL: URL!
    private var isBusy = false

    private var window: NSWindow!
    private var projectStack: NSStackView!
    private var statusLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var refreshButton: NSButton!
    private var logTextView: NSTextView!
    private var copyLogButton: NSButton!
    private var taskLog = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        loadConfiguration()
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if projects.isEmpty {
            setStatus("Конфигурация не загружена", color: .systemRed)
        } else {
            refreshAllStatuses()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func loadConfiguration() {
        let home = fileManager.homeDirectoryForCurrentUser
        let sourceURL = home
            .appendingPathComponent("My developed soft", isDirectory: true)
            .appendingPathComponent("Project Center", isDirectory: true)
            .appendingPathComponent("projects.json")
        let bundledURL = Bundle.main.url(forResource: "projects", withExtension: "json")
        let candidates = [sourceURL, bundledURL].compactMap { $0 }

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                let data = try Data(contentsOf: candidate)
                projects = try JSONDecoder().decode([ProjectDefinition].self, from: data)
                configURL = candidate
                break
            } catch {
                continue
            }
        }

        let sourceRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        projectsRootURL = sourceRoot
        justfileURL = sourceRoot.appendingPathComponent("justfile")
    }

    private func buildWindow() {
        let cardHeight: CGFloat = 64
        let cardSpacing: CGFloat = 8
        let listHeight = CGFloat(max(projects.count, 1)) * cardHeight
            + CGFloat(max(projects.count - 1, 0)) * cardSpacing
        let logPanelHeight: CGFloat = 184
        let minimumContentHeight = max(CGFloat(800), 68 + listHeight + 12 + logPanelHeight + 32)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: minimumContentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Project Center"
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        // Keep every project card visible while the task log stays pinned below
        // them. The log itself has its own scrollbar for long command output.
        window.minSize = NSSize(width: 880, height: minimumContentHeight)

        let content = NSView()
        window.contentView = content

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let headingStack = NSStackView()
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 2

        let title = NSTextField(labelWithString: "Push & Build Commander")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        headingStack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Текущая ветка · без auto-commit и force · сборки через общий justfile")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        headingStack.addArrangedSubview(subtitle)

        statusLabel = NSTextField(labelWithString: "Готово")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        headingStack.addArrangedSubview(statusLabel)
        header.addArrangedSubview(headingStack)

        header.addArrangedSubview(NSView())

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        header.addArrangedSubview(progressIndicator)

        refreshButton = NSButton(title: "Обновить", target: self, action: #selector(refreshStatuses(_:)))
        refreshButton.bezelStyle = .rounded
        header.addArrangedSubview(refreshButton)

        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        projectStack = NSStackView()
        projectStack.orientation = .vertical
        projectStack.alignment = .leading
        projectStack.spacing = 8
        projectStack.translatesAutoresizingMaskIntoConstraints = false

        for (index, project) in projects.enumerated() {
            let card = makeCard(project, index: index)
            cards.append(card)
            projectStack.addArrangedSubview(card.container)
            card.container.widthAnchor.constraint(equalTo: projectStack.widthAnchor).isActive = true
        }

        root.addArrangedSubview(projectStack)
        projectStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let taskLogPanel = makeTaskLogPanel(height: logPanelHeight)
        root.addArrangedSubview(taskLogPanel)
        taskLogPanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func makeTaskLogPanel(height: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor
        box.cornerRadius = 8
        box.fillColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        box.heightAnchor.constraint(equalToConstant: height).isActive = true

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = content

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let title = NSTextField(labelWithString: "Логи задачи")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        labels.addArrangedSubview(title)

        let hint = NSTextField(labelWithString: "Полный вывод последнего Push или Build")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        labels.addArrangedSubview(hint)
        header.addArrangedSubview(labels)
        header.addArrangedSubview(NSView())

        copyLogButton = NSButton(title: "Скопировать", target: self, action: #selector(copyTaskLog(_:)))
        copyLogButton.bezelStyle = .rounded
        copyLogButton.controlSize = .small
        copyLogButton.isEnabled = false
        header.addArrangedSubview(copyLogButton)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .tertiaryLabelColor
        textView.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = "Здесь появится полный вывод следующей задачи."
        logTextView = textView

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9)
        ])

        return box
    }

    private func makeCard(_ project: ProjectDefinition, index: Int) -> ProjectCard {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor
        box.cornerRadius = 8
        box.fillColor = NSColor(calibratedWhite: 0.13, alpha: 1)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        box.contentView = row

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let titleLabel = NSTextField(labelWithString: "\(project.name)   версия —")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        labels.addArrangedSubview(titleLabel)

        let gitLabel = NSTextField(labelWithString: "Статус обновляется…")
        gitLabel.font = .systemFont(ofSize: 12)
        gitLabel.textColor = .secondaryLabelColor
        gitLabel.lineBreakMode = .byTruncatingTail
        labels.addArrangedSubview(gitLabel)

        let lastOperationLabel = NSTextField(labelWithString: "Последняя операция: —")
        lastOperationLabel.font = .systemFont(ofSize: 11)
        lastOperationLabel.textColor = .tertiaryLabelColor
        lastOperationLabel.lineBreakMode = .byTruncatingTail
        labels.addArrangedSubview(lastOperationLabel)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labels)

        row.addArrangedSubview(NSView())

        let pushButton = actionButton(title: "Push", selector: #selector(pushProject(_:)), index: index)
        pushButton.contentTintColor = .systemOrange
        row.addArrangedSubview(pushButton)

        let buildButton = actionButton(title: project.buildLabel, selector: #selector(buildProject(_:)), index: index)
        row.addArrangedSubview(buildButton)

        let combinedButton = actionButton(title: "Push + Build", selector: #selector(pushAndBuildProject(_:)), index: index)
        row.addArrangedSubview(combinedButton)

        let launchButton = actionButton(title: "Запуск", selector: #selector(launchArtifact(_:)), index: index)
        launchButton.toolTip = "Запустить последнюю собранную версию"
        row.addArrangedSubview(launchButton)

        let revealArtifactButton = actionButton(title: "Место", selector: #selector(revealArtifact(_:)), index: index)
        revealArtifactButton.toolTip = "Показать последнюю сборку в Finder"
        row.addArrangedSubview(revealArtifactButton)

        box.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return ProjectCard(
            project: project,
            container: box,
            titleLabel: titleLabel,
            gitLabel: gitLabel,
            lastOperationLabel: lastOperationLabel,
            pushButton: pushButton,
            buildButton: buildButton,
            pushAndBuildButton: combinedButton,
            launchButton: launchButton,
            revealArtifactButton: revealArtifactButton
        )
    }

    private func actionButton(title: String, selector: Selector, index: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = index
        button.isEnabled = false
        return button
    }

    @objc private func refreshStatuses(_ sender: Any?) {
        refreshAllStatuses()
    }

    private func refreshAllStatuses() {
        guard !isBusy, !projects.isEmpty else { return }
        setBusy(true, status: "Обновление статусов…")

        operationQueue.async { [weak self] in
            guard let self else { return }
            let results = self.projects.map { project -> (GitSnapshot, URL?) in
                let snapshot = self.readSnapshot(for: project)
                let artifact = self.latestArtifact(for: project)
                return (snapshot, artifact)
            }

            DispatchQueue.main.async {
                for (index, result) in results.enumerated() where index < self.cards.count {
                    self.apply(result.0, artifact: result.1, to: self.cards[index])
                }
                self.setBusy(false, status: "Статусы обновлены")
            }
        }
    }

    @objc private func pushProject(_ sender: NSButton) {
        startOperation(.push, projectIndex: sender.tag)
    }

    @objc private func buildProject(_ sender: NSButton) {
        startOperation(.build, projectIndex: sender.tag)
    }

    @objc private func pushAndBuildProject(_ sender: NSButton) {
        startOperation(.pushAndBuild, projectIndex: sender.tag)
    }

    @objc private func launchArtifact(_ sender: NSButton) {
        guard cards.indices.contains(sender.tag) else { return }
        let card = cards[sender.tag]
        guard let artifact = card.latestArtifact else {
            showError("Запуск недоступен: для \(card.project.name) ещё нет готовой сборки.")
            return
        }
        NSWorkspace.shared.open(artifact)
    }

    @objc private func revealArtifact(_ sender: NSButton) {
        guard cards.indices.contains(sender.tag) else { return }
        let card = cards[sender.tag]
        guard let artifact = card.latestArtifact else {
            showError("Место недоступно: для \(card.project.name) ещё нет готовой сборки.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([artifact])
    }

    private func startOperation(_ kind: OperationKind, projectIndex: Int) {
        guard !isBusy, cards.indices.contains(projectIndex) else { return }
        let card = cards[projectIndex]

        if kind != .build {
            guard let snapshot = card.snapshot, snapshot.isRepository else {
                blockOperation(
                    kind,
                    for: card,
                    message: "Push недоступен: проект не является Git-репозиторием."
                )
                return
            }
            guard !snapshot.isDetached else {
                blockOperation(
                    kind,
                    for: card,
                    message: "Push недоступен: HEAD не привязан к ветке."
                )
                return
            }
            guard snapshot.hasCommit else {
                blockOperation(
                    kind,
                    for: card,
                    message: "Push недоступен: в репозитории ещё нет ни одного коммита."
                )
                return
            }
            guard snapshot.hasOrigin else {
                blockOperation(
                    kind,
                    for: card,
                    message: "Push недоступен: не настроен remote origin."
                )
                return
            }
        }

        setBusy(true, status: "\(kind.title): \(card.project.name)…")
        setTaskLog(
            "\(kind.title) · \(card.project.name)\n\nЗадача запущена. Полный вывод появится после завершения команды."
        )
        let operationStartedAt = Date()
        let recipes: [String]
        switch kind {
        case .push:
            recipes = [card.project.pushRecipe]
        case .build:
            recipes = [card.project.buildRecipe]
        case .pushAndBuild:
            recipes = [card.project.pushRecipe, card.project.buildRecipe]
        }

        operationQueue.async { [weak self] in
            guard let self else { return }
            var commandResults: [CommandResult] = []

            for recipe in recipes {
                let result = self.runJustRecipe(recipe)
                commandResults.append(result)
                if !result.succeeded {
                    break
                }
            }

            let snapshot = self.readSnapshot(for: card.project)
            let artifact = self.latestArtifact(for: card.project)
            let totalDuration = Date().timeIntervalSince(operationStartedAt)
            let succeeded = commandResults.count == recipes.count && commandResults.allSatisfy(\.succeeded)
            let failedResult = commandResults.first(where: { !$0.succeeded })

            DispatchQueue.main.async {
                self.apply(snapshot, artifact: artifact, to: card)
                self.updateLastOperation(card, kind: kind, succeeded: succeeded, duration: totalDuration)
                self.setTaskLog(
                    self.operationLog(
                        kind: kind,
                        project: card.project,
                        results: commandResults,
                        succeeded: succeeded,
                        duration: totalDuration
                    )
                )

                if succeeded {
                    self.setStatus("Успешно: \(kind.title) · \(card.project.name)", color: .systemGreen)
                } else {
                    let explanation = self.failureExplanation(for: failedResult, operation: kind)
                    self.setStatus("Ошибка: \(kind.title) · \(card.project.name) — \(explanation)", color: .systemRed)
                }
                self.finishBusyState()
            }
        }
    }

    private func blockOperation(_ kind: OperationKind, for card: ProjectCard, message: String) {
        setTaskLog(
            "\(kind.title) · \(card.project.name)\n\nКоманда не была запущена.\nПричина: \(message)"
        )
        showError(message)
    }

    private func operationLog(
        kind: OperationKind,
        project: ProjectDefinition,
        results: [CommandResult],
        succeeded: Bool,
        duration: TimeInterval
    ) -> String {
        var sections = [
            "\(kind.title) · \(project.name)",
            "Результат: \(succeeded ? "успех" : "ошибка")\nДлительность: \(formatDuration(duration))"
        ]

        for (index, result) in results.enumerated() {
            var section = "Команда \(index + 1) из \(results.count)\n$ \(result.command)\nРабочая папка: \(result.workingDirectory)"
            if let launchError = result.launchError {
                section += "\nОшибка запуска: \(launchError)"
            } else if let exitCode = result.exitCode {
                section += "\nКод завершения: \(exitCode)"
            }

            let output = result.output.trimmingCharacters(in: .newlines)
            section += "\n\nВывод команды:\n\(output.isEmpty ? "(команда не вывела текст)" : output)"
            sections.append(section)
        }

        return sections.joined(separator: "\n\n────────────────────────────────────────\n\n")
    }

    private func runJustRecipe(_ recipe: String) -> CommandResult {
        commandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["just", "--justfile", justfileURL.path, recipe],
            workingDirectory: projectsRootURL
        )
    }

    private func readSnapshot(for project: ProjectDefinition) -> GitSnapshot {
        let directory = URL(fileURLWithPath: project.path, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            return GitSnapshot(
                isRepository: false,
                branch: "путь не найден",
                isDetached: false,
                changedFiles: 0,
                hasCommit: false,
                hasOrigin: false,
                upstream: nil,
                ahead: 0,
                behind: 0,
                version: "—",
                error: "Папка проекта не найдена"
            )
        }

        let repoCheck = runGit(["rev-parse", "--is-inside-work-tree"], in: directory)
        guard repoCheck.succeeded, repoCheck.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return GitSnapshot(
                isRepository: false,
                branch: "не Git-репозиторий",
                isDetached: false,
                changedFiles: 0,
                hasCommit: false,
                hasOrigin: false,
                upstream: nil,
                ahead: 0,
                behind: 0,
                version: detectVersion(in: directory),
                error: "Не Git-репозиторий"
            )
        }

        let branchResult = runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        let isDetached = !branchResult.succeeded
        let hasCommit = runGit(["rev-parse", "--verify", "HEAD"], in: directory).succeeded
        let branch: String
        if isDetached {
            let sha = runGit(["rev-parse", "--short", "HEAD"], in: directory)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            branch = sha.isEmpty ? "detached HEAD" : "detached @ \(sha)"
        } else {
            branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let statusResult = runGit(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            in: directory
        )
        let changedFiles = statusResult.output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .filter { entry in
                entry.hasPrefix("1 ")
                    || entry.hasPrefix("2 ")
                    || entry.hasPrefix("u ")
                    || entry.hasPrefix("? ")
            }
            .count

        let originResult = runGit(["remote", "get-url", "origin"], in: directory)
        let hasOrigin = originResult.succeeded

        let upstreamResult = runGit(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: directory
        )
        let upstream = upstreamResult.succeeded
            ? upstreamResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        var ahead = 0
        var behind = 0
        if upstream != nil {
            let countsResult = runGit(
                ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
                in: directory
            )
            let parts = countsResult.output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            if parts.count >= 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }

        return GitSnapshot(
            isRepository: true,
            branch: branch,
            isDetached: isDetached,
            changedFiles: changedFiles,
            hasCommit: hasCommit,
            hasOrigin: hasOrigin,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            version: detectVersion(in: directory),
            error: nil
        )
    }

    private func runGit(_ arguments: [String], in directory: URL) -> CommandResult {
        commandRunner.run(executable: "/usr/bin/git", arguments: arguments, workingDirectory: directory)
    }

    private func detectVersion(in directory: URL) -> String {
        if let infoURL = findFile(named: "Info.plist", below: directory, maximumDepth: 4),
           let info = NSDictionary(contentsOf: infoURL),
           let version = info["CFBundleShortVersionString"] as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return version
        }

        for filename in ["version.json", "package.json"] {
            if let url = findFile(named: filename, below: directory, maximumDepth: 2),
               let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? String,
               !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return version
            }
        }

        if let pyprojectURL = findFile(named: "pyproject.toml", below: directory, maximumDepth: 2),
           let contents = try? String(contentsOf: pyprojectURL, encoding: .utf8),
           let version = firstMatch(
               pattern: #"(?m)^\s*version\s*=\s*["']([^"']+)["']"#,
               in: contents
           ) {
            return version
        }

        let tagResult = runGit(["describe", "--tags", "--abbrev=0"], in: directory)
        let tag = tagResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if tagResult.succeeded && !tag.isEmpty {
            return tag
        }

        let revisionResult = runGit(["rev-parse", "--short", "HEAD"], in: directory)
        let revision = revisionResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return revisionResult.succeeded && !revision.isEmpty ? "git-\(revision)" : "—"
    }

    private func findFile(named filename: String, below root: URL, maximumDepth: Int) -> URL? {
        var matches: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        let skippedDirectories: Set<String> = [
            ".git", ".build", ".build-cli", "node_modules", "Pods", "vendor", "dist"
        ]

        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard depth <= maximumDepth,
                  let children = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for child in children.sorted(by: { $0.path < $1.path }) {
                if child.lastPathComponent == filename {
                    matches.append(child)
                }
                guard depth < maximumDepth,
                      !skippedDirectories.contains(child.lastPathComponent),
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }
                queue.append((child, depth + 1))
            }
        }

        return matches.sorted { lhs, rhs in
            let lhsGenerated = lhs.path.contains(".app/Contents/")
            let rhsGenerated = rhs.path.contains(".app/Contents/")
            if lhsGenerated != rhsGenerated {
                return !lhsGenerated
            }
            return lhs.pathComponents.count < rhs.pathComponents.count
        }.first
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func latestArtifact(for project: ProjectDefinition) -> URL? {
        let baseURL = URL(fileURLWithPath: project.path, isDirectory: true)
        let candidates = project.artifactPaths.flatMap { expandArtifactPath($0, relativeTo: baseURL) }
        return candidates.max { lhs, rhs in
            modificationDate(of: lhs) < modificationDate(of: rhs)
        }
    }

    private func expandArtifactPath(_ pattern: String, relativeTo baseURL: URL) -> [URL] {
        let nsPattern = pattern as NSString
        let isAbsolute = nsPattern.isAbsolutePath
        var components = nsPattern.pathComponents
        var current = [isAbsolute ? URL(fileURLWithPath: "/", isDirectory: true) : baseURL]

        if isAbsolute, components.first == "/" {
            components.removeFirst()
        }

        for component in components {
            if component.contains("*") || component.contains("?") {
                current = current.flatMap { (directory: URL) -> [URL] in
                    guard let children = try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) else {
                        return []
                    }
                    return children.filter { wildcard(component, matches: $0.lastPathComponent) }
                }
            } else {
                current = current.map { $0.appendingPathComponent(component) }
            }
        }

        return current.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func wildcard(_ pattern: String, matches value: String) -> Bool {
        var escaped = NSRegularExpression.escapedPattern(for: pattern)
        escaped = escaped.replacingOccurrences(of: "\\*", with: ".*")
        escaped = escaped.replacingOccurrences(of: "\\?", with: ".")
        guard let expression = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]) else {
            return false
        }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func apply(_ snapshot: GitSnapshot, artifact: URL?, to card: ProjectCard) {
        card.snapshot = snapshot
        card.latestArtifact = artifact
        card.titleLabel.stringValue = "\(card.project.name)   версия \(snapshot.version)"

        if !snapshot.isRepository {
            card.gitLabel.stringValue = snapshot.error ?? "Git недоступен"
            card.gitLabel.textColor = .systemRed
        } else {
            var parts = [snapshot.branch]
            if snapshot.changedFiles == 0 {
                parts.append("clean")
            } else {
                parts.append("dirty: \(snapshot.changedFiles)")
            }

            if !snapshot.hasOrigin {
                parts.append("origin: нет")
            } else if let upstream = snapshot.upstream {
                parts.append("↑\(snapshot.ahead) ↓\(snapshot.behind)")
                parts.append(upstream)
            } else {
                parts.append("upstream: нет")
            }

            if !snapshot.hasCommit {
                parts.append("коммитов: нет")
            }

            card.gitLabel.stringValue = parts.joined(separator: "  ·  ")
            if !snapshot.hasOrigin || snapshot.isDetached || !snapshot.hasCommit {
                card.gitLabel.textColor = .systemOrange
            } else if snapshot.changedFiles > 0 {
                card.gitLabel.textColor = .systemYellow
            } else {
                card.gitLabel.textColor = .secondaryLabelColor
            }
        }

        updateActionAvailability()
    }

    private func updateLastOperation(
        _ card: ProjectCard,
        kind: OperationKind,
        succeeded: Bool,
        duration: TimeInterval
    ) {
        let result = succeeded ? "успех" : "ошибка"
        card.lastOperationLabel.stringValue =
            "Последняя: \(kind.title) — \(result) · \(formatDuration(duration))"
        card.lastOperationLabel.textColor = succeeded ? .systemGreen : .systemRed
    }

    private func setBusy(_ busy: Bool, status: String) {
        isBusy = busy
        setStatus(status, color: .secondaryLabelColor)
        if busy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        updateActionAvailability()
    }

    private func finishBusyState() {
        isBusy = false
        progressIndicator.stopAnimation(nil)
        updateActionAvailability()
    }

    private func updateActionAvailability() {
        refreshButton?.isEnabled = !isBusy
        for card in cards {
            // All project actions stay available when the app is idle. Their
            // handlers validate Git and artifact prerequisites and report a
            // specific problem, rather than leaving buttons mysteriously dimmed.
            card.pushButton.isEnabled = !isBusy
            card.buildButton.isEnabled = !isBusy
            card.pushAndBuildButton.isEnabled = !isBusy
            card.launchButton.isEnabled = !isBusy
            card.revealArtifactButton.isEnabled = !isBusy
        }
    }

    private func setTaskLog(_ text: String) {
        taskLog = text
        logTextView?.string = text
        logTextView?.textColor = .labelColor
        copyLogButton?.isEnabled = !text.isEmpty
        copyLogButton?.title = "Скопировать"

        // New operation details should start at the top even when the previous
        // log was long and the user had scrolled to its final error line.
        logTextView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    @objc private func copyTaskLog(_ sender: Any?) {
        guard !taskLog.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(taskLog, forType: .string)

        copyLogButton.title = "Скопировано"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyLogButton.title = "Скопировать"
        }
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
    }

    private func showError(_ message: String) {
        setStatus(message, color: .systemRed)
    }

    private func failureExplanation(
        for result: CommandResult?,
        operation: OperationKind
    ) -> String {
        guard let result else {
            return "Операция не была запущена."
        }

        let haystack = "\(result.output)\n\(result.launchError ?? "")".lowercased()
        if haystack.contains("no such remote") && haystack.contains("origin")
            || haystack.contains("has no origin remote")
            || haystack.contains("origin does not appear") {
            return "В репозитории не настроен remote origin."
        }
        if haystack.contains("has no upstream branch")
            || haystack.contains("no upstream configured")
            || haystack.contains("no upstream branch") {
            return "Для текущей ветки не настроен upstream."
        }
        if haystack.contains("authentication failed")
            || haystack.contains("permission denied (publickey)")
            || haystack.contains("could not read username")
            || haystack.contains("invalid username or password")
            || haystack.contains("authorization failed") {
            return "Git-аутентификация не прошла. Проверьте SSH-ключ или credentials."
        }
        if haystack.contains("command not found")
            || haystack.contains("no such file or directory")
            || result.exitCode == 127
            || result.launchError != nil {
            return "Не найдена команда, необходимая для операции."
        }
        if haystack.contains("cannot connect to the docker daemon")
            || haystack.contains("docker daemon is not running")
            || haystack.contains("error during connect")
            || haystack.contains("is the docker daemon running") {
            return "Docker не запущен или недоступен."
        }
        if operation == .build || operation == .pushAndBuild {
            return "Сборка завершилась с ошибкой."
        }
        return "Команда завершилась с ошибкой."
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1f с", duration)
        }
        let totalSeconds = Int(duration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
