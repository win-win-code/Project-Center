import AppKit
import QuartzCore

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
    let hasAgentsInstructions: Bool
    let branch: String
    let isDetached: Bool
    let changedFiles: Int
    let hasCommit: Bool
    let hasOrigin: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let originCommitDate: Date?
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
        case .push: return "Commit + Push"
        case .build: return "Build"
        case .pushAndBuild: return "Build + Commit + Push"
        }
    }
}

private enum OperationOutcome: Equatable {
    case succeeded
    case failed
    case skipped

    var title: String {
        switch self {
        case .succeeded: return "успех"
        case .failed: return "ошибка"
        case .skipped: return "не выполнено"
        }
    }
}

private final class ProjectCard {
    let project: ProjectDefinition
    let container: NSBox
    let heightConstraint: NSLayoutConstraint
    let agentsIndicator: NSView
    let titleLabel: NSTextField
    let gitLabel: NSTextField
    let originCommitLabel: NSTextField
    let lastOperationLabel: NSTextField
    let lastOperationDateLabel: NSTextField
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
        heightConstraint: NSLayoutConstraint,
        agentsIndicator: NSView,
        titleLabel: NSTextField,
        gitLabel: NSTextField,
        originCommitLabel: NSTextField,
        lastOperationLabel: NSTextField,
        lastOperationDateLabel: NSTextField,
        pushButton: NSButton,
        buildButton: NSButton,
        pushAndBuildButton: NSButton,
        launchButton: NSButton,
        revealArtifactButton: NSButton
    ) {
        self.project = project
        self.container = container
        self.heightConstraint = heightConstraint
        self.agentsIndicator = agentsIndicator
        self.titleLabel = titleLabel
        self.gitLabel = gitLabel
        self.originCommitLabel = originCommitLabel
        self.lastOperationLabel = lastOperationLabel
        self.lastOperationDateLabel = lastOperationDateLabel
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSSplitViewDelegate {
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
    private var zoomEventMonitor: Any?
    private var zoomableControls: [(NSControl, NSFont)] = []
    private var zoomableTextViews: [(NSTextView, NSFont)] = []
    private var interfaceZoom: CGFloat = 1

    private let minimumInterfaceZoom: CGFloat = 0.8
    private let maximumInterfaceZoom: CGFloat = 1.5
    private let interfaceZoomStep: CGFloat = 0.1

    private let originCommitDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private let lastOperationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private let minimumProjectPaneHeight: CGFloat = 150
    private let minimumLogPanelHeight: CGFloat = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        loadConfiguration()
        buildWindow()
        installZoomKeyboardShortcuts()
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

    func applicationWillTerminate(_ notification: Notification) {
        if let zoomEventMonitor {
            NSEvent.removeMonitor(zoomEventMonitor)
        }
    }

    private func loadConfiguration() {
        let home = fileManager.homeDirectoryForCurrentUser
        let sourceURL = home
            .appendingPathComponent("My soft", isDirectory: true)
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

        // A split view provides the native draggable divider between the
        // projects and the task log. Project cards stay available in a scroll
        // view when the user gives more vertical space to the log.
        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            splitView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        let projectPane = NSView()

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
        registerZoomable(title)
        headingStack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Push автоматически фиксирует все изменения · без force · сборки через общий justfile")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        registerZoomable(subtitle)
        headingStack.addArrangedSubview(subtitle)

        statusLabel = NSTextField(labelWithString: "Готово")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        registerZoomable(statusLabel)
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
        registerZoomable(refreshButton)
        header.addArrangedSubview(refreshButton)

        header.translatesAutoresizingMaskIntoConstraints = false
        projectPane.addSubview(header)

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

        let projectScrollView = NSScrollView()
        projectScrollView.borderType = .noBorder
        projectScrollView.hasVerticalScroller = true
        projectScrollView.autohidesScrollers = true
        projectScrollView.drawsBackground = false
        projectScrollView.documentView = projectStack
        projectScrollView.translatesAutoresizingMaskIntoConstraints = false
        projectPane.addSubview(projectScrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: projectPane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: projectPane.trailingAnchor),
            header.topAnchor.constraint(equalTo: projectPane.topAnchor),
            projectScrollView.leadingAnchor.constraint(equalTo: projectPane.leadingAnchor),
            projectScrollView.trailingAnchor.constraint(equalTo: projectPane.trailingAnchor),
            projectScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            projectScrollView.bottomAnchor.constraint(equalTo: projectPane.bottomAnchor),
            projectStack.leadingAnchor.constraint(equalTo: projectScrollView.contentView.leadingAnchor),
            projectStack.trailingAnchor.constraint(equalTo: projectScrollView.contentView.trailingAnchor),
            projectStack.topAnchor.constraint(equalTo: projectScrollView.contentView.topAnchor),
            projectStack.widthAnchor.constraint(equalTo: projectScrollView.contentView.widthAnchor)
        ])
        projectStack.setContentHuggingPriority(.required, for: .vertical)
        projectStack.setContentCompressionResistancePriority(.required, for: .vertical)

        let taskLogPanel = makeTaskLogPanel()
        splitView.addArrangedSubview(projectPane)
        splitView.addArrangedSubview(taskLogPanel)

        // NSSplitView uses physical coordinates for the divider. Depending on
        // the subview ordering used by AppKit, the first pane can be above or
        // below the divider, so determine the matching initial position after
        // its first layout pass.
        let projectPaneHeight = minimumContentHeight - 32 - logPanelHeight - splitView.dividerThickness
        DispatchQueue.main.async {
            splitView.layoutSubtreeIfNeeded()
            let firstPaneIsAboveDivider = projectPane.frame.minY > 0
            let dividerPosition = firstPaneIsAboveDivider ? logPanelHeight : projectPaneHeight
            splitView.setPosition(dividerPosition, ofDividerAt: 0)
        }
    }

    private func makeTaskLogPanel() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor
        box.cornerRadius = 8
        box.fillColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        let content = NSView()
        // NSBox owns the frame of its content view. Keeping the autoresizing
        // mask here lets the content fill the box; disabling it without
        // replacement constraints collapses the scroll view for the logs.
        content.autoresizingMask = [.width, .height]
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
        registerZoomable(title)
        labels.addArrangedSubview(title)

        let hint = NSTextField(labelWithString: "Полный вывод последнего Push или Build")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        registerZoomable(hint)
        labels.addArrangedSubview(hint)
        header.addArrangedSubview(labels)
        header.addArrangedSubview(NSView())

        copyLogButton = NSButton(title: "Скопировать", target: self, action: #selector(copyTaskLog(_:)))
        copyLogButton.bezelStyle = .rounded
        copyLogButton.controlSize = .small
        copyLogButton.isEnabled = false
        registerZoomable(copyLogButton)
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
        registerZoomable(textView)

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

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard
            !splitView.isVertical,
            dividerIndex == 0,
            let projectPane = splitView.arrangedSubviews.first
        else {
            return proposedPosition
        }

        let projectPaneIsAboveDivider = projectPane.frame.minY > 0
        let lowerPaneMinimum = projectPaneIsAboveDivider
            ? minimumLogPanelHeight
            : minimumProjectPaneHeight
        let upperPaneMinimum = projectPaneIsAboveDivider
            ? minimumProjectPaneHeight
            : minimumLogPanelHeight
        let maximumPosition = splitView.bounds.height - splitView.dividerThickness - upperPaneMinimum

        return min(max(proposedPosition, lowerPaneMinimum), maximumPosition)
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

        let agentsIndicator = NSView()
        agentsIndicator.wantsLayer = true
        agentsIndicator.layer?.backgroundColor = NSColor.systemRed.cgColor
        agentsIndicator.layer?.cornerRadius = 4
        agentsIndicator.toolTip = "В корне проекта нет AGENTS.md"
        agentsIndicator.isHidden = true
        agentsIndicator.widthAnchor.constraint(equalToConstant: 8).isActive = true
        agentsIndicator.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let titleLabel = NSTextField(labelWithString: "\(project.name)   версия —")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        registerZoomable(titleLabel)

        let titleRow = NSStackView(views: [agentsIndicator, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.addArrangedSubview(titleRow)

        let gitLabel = NSTextField(labelWithString: "Статус обновляется…")
        gitLabel.font = .systemFont(ofSize: 12)
        gitLabel.textColor = .secondaryLabelColor
        gitLabel.lineBreakMode = .byTruncatingTail
        registerZoomable(gitLabel)

        let originCommitLabel = NSTextField(labelWithString: "")
        originCommitLabel.font = .systemFont(ofSize: 12, weight: .medium)
        originCommitLabel.lineBreakMode = .byTruncatingTail
        originCommitLabel.isHidden = true
        originCommitLabel.wantsLayer = true
        registerZoomable(originCommitLabel)

        let gitStatusRow = NSStackView(views: [gitLabel, originCommitLabel])
        gitStatusRow.orientation = .horizontal
        gitStatusRow.alignment = .centerY
        gitStatusRow.spacing = 10
        gitLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        originCommitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        labels.addArrangedSubview(gitStatusRow)

        let lastOperationLabel = NSTextField(labelWithString: "Последняя операция: —")
        lastOperationLabel.font = .systemFont(ofSize: 11)
        lastOperationLabel.textColor = .tertiaryLabelColor
        lastOperationLabel.lineBreakMode = .byTruncatingTail
        registerZoomable(lastOperationLabel)

        let lastOperationDateLabel = NSTextField(labelWithString: "")
        lastOperationDateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        lastOperationDateLabel.textColor = .tertiaryLabelColor
        lastOperationDateLabel.lineBreakMode = .byTruncatingTail
        lastOperationDateLabel.isHidden = true
        lastOperationDateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        registerZoomable(lastOperationDateLabel)

        let lastOperationRow = NSStackView(views: [lastOperationLabel, NSView(), lastOperationDateLabel])
        lastOperationRow.orientation = .horizontal
        lastOperationRow.alignment = .centerY
        lastOperationRow.spacing = 8
        lastOperationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.addArrangedSubview(lastOperationRow)
        lastOperationRow.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labels)

        row.addArrangedSubview(NSView())

        let pushButton = actionButton(title: "Commit + Push", selector: #selector(pushProject(_:)), index: index)
        pushButton.contentTintColor = .systemOrange
        pushButton.toolTip = "Зафиксировать все изменения и отправить их в origin"
        row.addArrangedSubview(pushButton)

        let buildButton = actionButton(title: project.buildLabel, selector: #selector(buildProject(_:)), index: index)
        row.addArrangedSubview(buildButton)

        let combinedButton = actionButton(title: "Build + Commit + Push", selector: #selector(pushAndBuildProject(_:)), index: index)
        combinedButton.toolTip = "Сначала собрать проект, затем зафиксировать все изменения и отправить их в origin"
        row.addArrangedSubview(combinedButton)

        let launchButton = actionButton(title: "Запуск", selector: #selector(launchArtifact(_:)), index: index)
        launchButton.toolTip = "Запустить последнюю собранную версию"
        row.addArrangedSubview(launchButton)

        let revealArtifactButton = actionButton(title: "Место", selector: #selector(revealArtifact(_:)), index: index)
        revealArtifactButton.toolTip = "Показать последнюю сборку в Finder"
        row.addArrangedSubview(revealArtifactButton)

        let heightConstraint = box.heightAnchor.constraint(equalToConstant: 64)
        heightConstraint.isActive = true
        return ProjectCard(
            project: project,
            container: box,
            heightConstraint: heightConstraint,
            agentsIndicator: agentsIndicator,
            titleLabel: titleLabel,
            gitLabel: gitLabel,
            originCommitLabel: originCommitLabel,
            lastOperationLabel: lastOperationLabel,
            lastOperationDateLabel: lastOperationDateLabel,
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
        registerZoomable(button)
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

        setBusy(true, status: "\(kind.title): \(card.project.name)…")
        setTaskLog(
            "\(kind.title) · \(card.project.name)\n\nПроверяется актуальное состояние проекта."
        )
        let operationStartedAt = Date()

        operationQueue.async { [weak self] in
            guard let self else { return }
            var commandResults: [CommandResult] = []
            var notes: [String] = []
            var outcome: OperationOutcome = .failed
            var message: String?
            let snapshot: GitSnapshot

            switch kind {
            case .build:
                let result = self.runJustRecipe(card.project.buildRecipe)
                commandResults.append(result)
                snapshot = self.readSnapshot(for: card.project)
                outcome = result.succeeded ? .succeeded : .failed

            case .push:
                var currentSnapshot = self.readSnapshot(for: card.project)

                if let blockReason = self.pushBlockReason(for: currentSnapshot) {
                    message = blockReason
                    notes.append("Команда Push не была запущена.\nПричина: \(blockReason)")
                    outcome = .failed
                } else if let commitFailure = self.createAutomaticCommitIfNeeded(
                    for: card.project,
                    snapshot: currentSnapshot,
                    commandResults: &commandResults,
                    notes: &notes
                ) {
                    currentSnapshot = self.readSnapshot(for: card.project)
                    message = commitFailure
                    outcome = .failed
                } else {
                    currentSnapshot = self.readSnapshot(for: card.project)

                    let pushExecution = self.pushPendingCommits(
                        for: card.project,
                        snapshot: &currentSnapshot,
                        commandResults: &commandResults,
                        notes: &notes
                    )
                    outcome = pushExecution.outcome
                    message = pushExecution.message
                }

                snapshot = currentSnapshot

            case .pushAndBuild:
                var currentSnapshot = self.readSnapshot(for: card.project)

                if let blockReason = self.pushBlockReason(for: currentSnapshot) {
                    message = blockReason
                    notes.append("Команды Build, Commit и Push не были запущены.\nПричина: \(blockReason)")
                    outcome = .failed
                } else {
                    notes.append("Порядок операции: Build → Commit → Push.")
                    let buildResult = self.runJustRecipe(card.project.buildRecipe)
                    commandResults.append(buildResult)
                    currentSnapshot = self.readSnapshot(for: card.project)

                    if !buildResult.succeeded {
                        outcome = .failed
                    } else if let commitFailure = self.createAutomaticCommitIfNeeded(
                        for: card.project,
                        snapshot: currentSnapshot,
                        commandResults: &commandResults,
                        notes: &notes
                    ) {
                        currentSnapshot = self.readSnapshot(for: card.project)
                        message = commitFailure
                        outcome = .failed
                    } else {
                        currentSnapshot = self.readSnapshot(for: card.project)
                        let pushExecution = self.pushPendingCommits(
                            for: card.project,
                            snapshot: &currentSnapshot,
                            commandResults: &commandResults,
                            notes: &notes
                        )

                        if pushExecution.outcome == .skipped {
                            notes.append("Сборка выполнена; новых коммитов для отправки нет.")
                            outcome = .succeeded
                        } else {
                            outcome = pushExecution.outcome
                            message = pushExecution.message
                        }
                    }
                }

                snapshot = currentSnapshot
            }

            let artifact = self.latestArtifact(for: card.project)
            let totalDuration = Date().timeIntervalSince(operationStartedAt)
            let operationCompletedAt = Date()
            let failedResult = commandResults.first(where: { !$0.succeeded })
            let statusMessage: String
            switch outcome {
            case .succeeded:
                statusMessage = "Успешно: \(kind.title) · \(card.project.name)"
            case .skipped:
                statusMessage = message ?? "Операция не выполнена."
            case .failed:
                statusMessage = message ?? self.failureExplanation(for: failedResult, operation: kind)
            }

            DispatchQueue.main.async {
                self.apply(snapshot, artifact: artifact, to: card)
                self.updateLastOperation(
                    card,
                    kind: kind,
                    outcome: outcome,
                    duration: totalDuration,
                    completedAt: operationCompletedAt
                )
                self.setTaskLog(
                    self.operationLog(
                        kind: kind,
                        project: card.project,
                        results: commandResults,
                        outcome: outcome,
                        notes: notes,
                        duration: totalDuration
                    )
                )

                switch outcome {
                case .succeeded:
                    self.setStatus(statusMessage, color: .systemGreen)
                case .skipped:
                    self.setStatus(statusMessage, color: .secondaryLabelColor)
                case .failed:
                    self.setStatus("Ошибка: \(kind.title) · \(card.project.name) — \(statusMessage)", color: .systemRed)
                }
                self.finishBusyState()
            }
        }
    }

    private func operationLog(
        kind: OperationKind,
        project: ProjectDefinition,
        results: [CommandResult],
        outcome: OperationOutcome,
        notes: [String],
        duration: TimeInterval
    ) -> String {
        var sections = [
            "\(kind.title) · \(project.name)",
            "Результат: \(outcome.title)\nДлительность: \(formatDuration(duration))"
        ]
        sections.append(contentsOf: notes)

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

    private func pushBlockReason(for snapshot: GitSnapshot) -> String? {
        guard snapshot.isRepository else {
            return "Push недоступен: проект не является Git-репозиторием."
        }
        guard !snapshot.isDetached else {
            return "Push недоступен: HEAD не привязан к ветке."
        }
        guard snapshot.hasCommit else {
            return "Push недоступен: в репозитории ещё нет ни одного коммита."
        }
        guard snapshot.hasOrigin else {
            return "Push недоступен: не настроен remote origin."
        }
        guard snapshot.upstream != nil else {
            return "Push недоступен: для текущей ветки не настроен upstream."
        }
        return nil
    }

    private func pushPreparationNote(for snapshot: GitSnapshot) -> String {
        let workingTreeStatus = snapshot.changedFiles == 0
            ? "clean"
            : "незакоммичено: \(snapshot.changedFiles)"
        var lines = [
            "Актуальный Git-статус перед Push: \(workingTreeStatus), ↑\(snapshot.ahead) ↓\(snapshot.behind).",
            "Будут отправлены только \(snapshot.ahead) готовых коммитов."
        ]
        if snapshot.changedFiles > 0 {
            lines.append("Push не будет запущен, пока все изменения не войдут в коммит.")
        }
        return lines.joined(separator: "\n")
    }

    private func pushPendingCommits(
        for project: ProjectDefinition,
        snapshot: inout GitSnapshot,
        commandResults: inout [CommandResult],
        notes: inout [String]
    ) -> (outcome: OperationOutcome, message: String?) {
        guard snapshot.ahead > 0 else {
            let message: String
            if snapshot.behind > 0 {
                message = "Нечего отправлять: локальных коммитов для Push нет, но origin опережает ветку на \(snapshot.behind) коммитов. Сначала получите обновления."
            } else {
                message = "Нечего отправлять: локальная ветка уже совпадает с origin."
            }
            notes.append("Команда Push не была запущена.\nПричина: \(message)")
            return (.skipped, message)
        }

        notes.append(pushPreparationNote(for: snapshot))
        let pushResult = runJustRecipe(project.pushRecipe)
        commandResults.append(pushResult)
        snapshot = readSnapshot(for: project)

        guard pushResult.succeeded else {
            return (.failed, nil)
        }
        guard snapshot.upstream != nil else {
            let message = "Push завершился без ошибки, но после него не удалось определить upstream для проверки результата."
            notes.append(message)
            return (.failed, message)
        }
        guard snapshot.ahead == 0 else {
            let message = "Push завершился без ошибки, но осталось \(snapshot.ahead) неотправленных коммитов. Проверьте настройки remote/upstream и вывод команды."
            notes.append(message)
            return (.failed, message)
        }
        return (.succeeded, nil)
    }

    private func createAutomaticCommitIfNeeded(
        for project: ProjectDefinition,
        snapshot: GitSnapshot,
        commandResults: inout [CommandResult],
        notes: inout [String]
    ) -> String? {
        guard snapshot.changedFiles > 0 else {
            return nil
        }

        notes.append("Подготовка автоматического коммита из \(snapshot.changedFiles) изменений.")
        let addResult = runGit(["add", "-A"], in: URL(fileURLWithPath: project.path, isDirectory: true))
        commandResults.append(addResult)
        guard addResult.succeeded else {
            return "Не удалось добавить изменения в коммит. Push не выполнялся."
        }

        let commitMessage = "Автоматический коммит из Project Center"
        let commitResult = runGit(
            ["commit", "-m", commitMessage],
            in: URL(fileURLWithPath: project.path, isDirectory: true)
        )
        commandResults.append(commitResult)
        guard commitResult.succeeded else {
            return "Не удалось создать коммит. Push не выполнялся."
        }

        let updatedSnapshot = readSnapshot(for: project)
        guard updatedSnapshot.changedFiles == 0 else {
            return "После автоматического коммита остались незакоммиченные изменения. Push не выполнялся."
        }

        notes.append("Создан коммит: \(commitMessage).")
        return nil
    }

    private func readSnapshot(for project: ProjectDefinition) -> GitSnapshot {
        let directory = URL(fileURLWithPath: project.path, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            return GitSnapshot(
                isRepository: false,
                hasAgentsInstructions: false,
                branch: "путь не найден",
                isDetached: false,
                changedFiles: 0,
                hasCommit: false,
                hasOrigin: false,
                upstream: nil,
                ahead: 0,
                behind: 0,
                originCommitDate: nil,
                version: "—",
                error: "Папка проекта не найдена"
            )
        }

        let hasAgentsInstructions = hasAgentsInstructions(in: directory)
        let repoCheck = runGit(["rev-parse", "--is-inside-work-tree"], in: directory)
        guard repoCheck.succeeded, repoCheck.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return GitSnapshot(
                isRepository: false,
                hasAgentsInstructions: hasAgentsInstructions,
                branch: "не Git-репозиторий",
                isDetached: false,
                changedFiles: 0,
                hasCommit: false,
                hasOrigin: false,
                upstream: nil,
                ahead: 0,
                behind: 0,
                originCommitDate: nil,
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
        var originCommitDate: Date?
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

            let originCommitResult = runGit(["log", "-1", "--format=%cI", "@{upstream}"], in: directory)
            let originCommitDateText = originCommitResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            originCommitDate = originCommitResult.succeeded
                ? ISO8601DateFormatter().date(from: originCommitDateText)
                : nil
        }

        return GitSnapshot(
            isRepository: true,
            hasAgentsInstructions: hasAgentsInstructions,
            branch: branch,
            isDetached: isDetached,
            changedFiles: changedFiles,
            hasCommit: hasCommit,
            hasOrigin: hasOrigin,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            originCommitDate: originCommitDate,
            version: detectVersion(in: directory),
            error: nil
        )
    }

    private func hasAgentsInstructions(in directory: URL) -> Bool {
        ["AGENTS.md", "agents.md"].contains { filename in
            let fileURL = directory.appendingPathComponent(filename)
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
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
        card.agentsIndicator.isHidden = snapshot.hasAgentsInstructions

        if !snapshot.isRepository {
            card.gitLabel.stringValue = snapshot.error ?? "Git недоступен"
            card.gitLabel.textColor = .systemRed
        } else {
            var parts = [snapshot.branch]
            if snapshot.changedFiles == 0 {
                parts.append("clean")
            } else {
                parts.append("незакоммичено: \(snapshot.changedFiles)")
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

        updateOriginCommitIndicator(snapshot, for: card)
        updateActionAvailability()
    }

    private func updateOriginCommitIndicator(_ snapshot: GitSnapshot, for card: ProjectCard) {
        let label = card.originCommitLabel
        label.layer?.removeAnimation(forKey: "originCommitAhead")
        label.layer?.opacity = 1

        guard snapshot.isRepository, let originCommitDate = snapshot.originCommitDate else {
            label.isHidden = true
            return
        }

        label.isHidden = false
        label.stringValue = "Origin: \(originCommitDateFormatter.string(from: originCommitDate))"

        // This is the date of the latest commit in upstream, not the time of
        // the last Push operation. Highlight it only when local commits are ahead.
        guard snapshot.ahead > 0 else {
            label.textColor = .tertiaryLabelColor
            return
        }

        label.textColor = .systemRed
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 1.4
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        label.layer?.add(pulse, forKey: "originCommitAhead")
    }

    private func updateLastOperation(
        _ card: ProjectCard,
        kind: OperationKind,
        outcome: OperationOutcome,
        duration: TimeInterval,
        completedAt: Date
    ) {
        card.lastOperationLabel.stringValue =
            "Последняя: \(kind.title) — \(outcome.title) · \(formatDuration(duration))"
        switch outcome {
        case .succeeded:
            card.lastOperationLabel.textColor = .systemGreen
        case .failed:
            card.lastOperationLabel.textColor = .systemRed
        case .skipped:
            card.lastOperationLabel.textColor = .secondaryLabelColor
        }
        card.lastOperationDateLabel.stringValue = lastOperationDateFormatter.string(from: completedAt)
        card.lastOperationDateLabel.isHidden = false
        card.lastOperationDateLabel.textColor = .tertiaryLabelColor
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

    private func registerZoomable(_ control: NSControl) {
        guard let font = control.font else { return }
        zoomableControls.append((control, font))
    }

    private func registerZoomable(_ textView: NSTextView) {
        guard let font = textView.font else { return }
        zoomableTextViews.append((textView, font))
    }

    private func installZoomKeyboardShortcuts() {
        zoomEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                  !modifiers.contains(.control),
                  !modifiers.contains(.option) else {
                return event
            }

            switch event.keyCode {
            case 24: // = / +
                self.changeInterfaceZoom(by: self.interfaceZoomStep)
                return nil
            case 27: // - / _
                self.changeInterfaceZoom(by: -self.interfaceZoomStep)
                return nil
            case 29: // 0
                self.setInterfaceZoom(1)
                return nil
            default:
                return event
            }
        }
    }

    private func changeInterfaceZoom(by delta: CGFloat) {
        setInterfaceZoom(interfaceZoom + delta)
    }

    private func setInterfaceZoom(_ requestedZoom: CGFloat) {
        let roundedZoom = (requestedZoom / interfaceZoomStep).rounded() * interfaceZoomStep
        let newZoom = min(max(roundedZoom, minimumInterfaceZoom), maximumInterfaceZoom)
        guard abs(newZoom - interfaceZoom) > 0.001 else { return }

        interfaceZoom = newZoom
        for (control, baseFont) in zoomableControls {
            control.font = baseFont.withSize(baseFont.pointSize * newZoom)
        }
        for (textView, baseFont) in zoomableTextViews {
            textView.font = baseFont.withSize(baseFont.pointSize * newZoom)
        }
        for card in cards {
            card.heightConstraint.constant = 64 * newZoom
        }
        projectStack.spacing = 8 * newZoom
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()

        setStatus("Масштаб: \(Int((newZoom * 100).rounded()))%", color: .secondaryLabelColor)
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
        if operation == .build {
            return "Сборка завершилась с ошибкой."
        }
        if operation == .pushAndBuild {
            return "Одна из команд Push или Build завершилась с ошибкой."
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
