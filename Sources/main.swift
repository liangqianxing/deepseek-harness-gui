import Cocoa
import WebKit
import Darwin

private let defaultPort = Int(ProcessInfo.processInfo.environment["DSH_GUI_PORT"] ?? "3080") ?? 3080

enum DSHServiceState {
    case checking
    case starting(port: Int)
    case running(port: Int, owned: Bool)
    case stopping(port: Int)
    case stopped(port: Int)
    case failed(port: Int, message: String)
}

final class DSHServiceController {
    var onStateChanged: ((DSHServiceState) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "io.github.liangqianxing.deepseek-harness-gui.service", qos: .userInitiated)
    private var process: Process?
    private var monitor: DispatchSourceTimer?
    private var currentPort: Int
    private var ownsProcess = false
    private var stopping = false
    private var restartRequested = false
    private var failureAfterTermination: String?
    private var readinessCheckStarted = false
    private var consecutiveProbeFailures = 0

    init(port: Int = defaultPort) {
        currentPort = port
    }

    func bootstrap() {
        publish(.checking)
        log("正在检查 http://localhost:\(currentPort) …")
        probeDSHWithRetry(port: currentPort, attemptsRemaining: 3) { [weak self] available in
            guard let self else { return }
            self.queue.async {
                if available {
                    self.ownsProcess = false
                    self.log("检测到已运行的 dsh，直接复用，避免重复启动。")
                    self.publish(.running(port: self.currentPort, owned: false))
                    self.startMonitor()
                } else {
                    self.startLocked(preferredPort: self.currentPort)
                }
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startLocked(preferredPort: self.currentPort)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked(restart: false)
        }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ownsProcess, self.process?.isRunning == true else {
                self.log("当前服务由外部终端启动；GUI 不会终止不属于自己的进程。")
                return
            }
            self.stopLocked(restart: true)
        }
    }

    func terminateOwnedProcessOnExit() {
        let managedProcess: Process? = queue.sync {
            guard ownsProcess, let process, process.isRunning else { return nil }
            stopping = true
            process.terminate()
            return process
        }
        guard let managedProcess else { return }

        let deadline = Date().addingTimeInterval(3)
        while managedProcess.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if managedProcess.isRunning {
            kill(managedProcess.processIdentifier, SIGKILL)
            managedProcess.waitUntilExit()
        }
    }

    private func startLocked(preferredPort: Int) {
        if let process, process.isRunning {
            log("dsh 已由 GUI 启动，PID \(process.processIdentifier)。")
            return
        }

        probeDSHWithRetry(port: preferredPort, attemptsRemaining: 3) { [weak self] available in
            guard let self else { return }
            self.queue.async {
                if available {
                    self.currentPort = preferredPort
                    self.ownsProcess = false
                    self.publish(.running(port: preferredPort, owned: false))
                    self.startMonitor()
                    return
                }

                if self.portIsOccupied(preferredPort) {
                    self.log("端口 \(preferredPort) 已被其他程序占用，交给系统自动选择端口。")
                    self.launch(port: 0)
                } else {
                    self.launch(port: preferredPort)
                }
            }
        }
    }

    private func launch(port: Int) {
        guard let launcher = Bundle.main.path(forResource: "start-dsh", ofType: "sh") else {
            publish(.failed(port: port, message: "应用内缺少 start-dsh.sh"))
            return
        }

        currentPort = port
        consecutiveProbeFailures = 0
        stopping = false
        failureAfterTermination = nil
        readinessCheckStarted = false
        publish(.starting(port: port))
        log(port == 0 ? "启动 dsh，自动选择端口…" : "启动 dsh，端口 \(port)…")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [launcher, String(port)]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferredPath = [
            "\(home)/.local/bin",
            "\(home)/.hermes/node/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ].joined(separator: ":")
        environment["PATH"] = preferredPath + ":" + (environment["PATH"] ?? "")
        environment["DSH_GUI_LAUNCH"] = "1"
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.handleProcessOutput(text, task: task)
        }

        process = task
        ownsProcess = true
        task.terminationHandler = { [weak self, weak task] terminated in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                guard self.process === task else { return }
                let status = terminated.terminationStatus
                self.process = nil
                self.ownsProcess = false
                self.stopMonitor()
                if let failure = self.failureAfterTermination {
                    self.failureAfterTermination = nil
                    self.restartRequested = false
                    self.stopping = false
                    self.log(failure)
                    self.publish(.failed(port: self.currentPort, message: failure))
                } else if self.restartRequested {
                    self.restartRequested = false
                    self.stopping = false
                    self.log("旧进程已退出，重新启动 dsh。")
                    self.launch(port: self.currentPort)
                } else if self.stopping {
                    self.stopping = false
                    self.log("dsh 已停止（退出状态 \(status)）。")
                    self.publish(.stopped(port: self.currentPort))
                } else {
                    let message = "dsh 进程已退出，状态 \(status)"
                    self.log(message)
                    self.publish(.failed(port: self.currentPort, message: message))
                }
            }
        }

        do {
            try task.run()
            log("dsh PID: \(task.processIdentifier)")
            if port == 0 {
                queue.asyncAfter(deadline: .now() + 40) { [weak self, weak task] in
                    guard let self, self.process === task, !self.readinessCheckStarted else { return }
                    self.failManagedProcess(message: "等待 dsh 分配端口超时")
                }
            } else {
                readinessCheckStarted = true
                waitUntilReady(port: port, attemptsRemaining: 80)
            }
        } catch {
            process = nil
            ownsProcess = false
            publish(.failed(port: port, message: error.localizedDescription))
            log("启动失败：\(error.localizedDescription)")
        }
    }

    private func waitUntilReady(port: Int, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            failManagedProcess(message: "等待 dsh 启动超时")
            return
        }
        guard process?.isRunning == true else { return }

        probeDSH(port: port) { [weak self] available in
            guard let self else { return }
            self.queue.async {
                if available {
                    self.log("dsh 已就绪：http://localhost:\(port)")
                    self.publish(.running(port: port, owned: true))
                    self.startMonitor()
                } else {
                    self.queue.asyncAfter(deadline: .now() + 0.5) {
                        self.waitUntilReady(port: port, attemptsRemaining: attemptsRemaining - 1)
                    }
                }
            }
        }
    }

    private func stopLocked(restart: Bool) {
        guard ownsProcess, let process, process.isRunning else {
            log("当前是外部 dsh 实例，GUI 仅复用，不会强制停止。")
            return
        }
        restartRequested = restart
        stopping = true
        publish(.stopping(port: currentPort))
        log(restart ? "正在重启 dsh…" : "正在停止 dsh…")
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 4) { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            self.log("dsh 未在 4 秒内退出，结束 PID \(pid)。")
            kill(pid, SIGKILL)
        }
    }

    private func startMonitor() {
        stopMonitor()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.probeDSH(port: self.currentPort) { available in
                self.queue.async {
                    if available {
                        self.consecutiveProbeFailures = 0
                    } else {
                        self.consecutiveProbeFailures += 1
                        if self.consecutiveProbeFailures >= 3 {
                            self.stopMonitor()
                            if self.ownsProcess, self.process?.isRunning == true {
                                self.failManagedProcess(message: "dsh 页面连续三次不可达")
                            } else {
                                self.ownsProcess = false
                                self.publish(.stopped(port: self.currentPort))
                            }
                        }
                    }
                }
            }
        }
        monitor = timer
        timer.resume()
    }

    private func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    private func probeDSH(port: Int, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://localhost:\(port)/") else {
            completion(false)
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        session.dataTask(with: url) { data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                completion(false)
                return
            }
            let body = String(decoding: data.prefix(16_384), as: UTF8.self)
            completion(body.contains("__DSH_BOOT__"))
        }.resume()
    }

    private func probeDSHWithRetry(port: Int, attemptsRemaining: Int, completion: @escaping (Bool) -> Void) {
        probeDSH(port: port) { [weak self] available in
            guard let self else { return }
            if available || attemptsRemaining <= 1 {
                completion(available)
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                self.probeDSHWithRetry(
                    port: port,
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
            }
        }
    }

    private func handleProcessOutput(_ output: String, task: Process?) {
        let text = output.trimmingCharacters(in: .newlines)
        log(text)
        guard let task,
              let match = text.range(of: #"dsh web: http://127\.0\.0\.1:(\d+)"#, options: .regularExpression),
              let port = Int(text[match].split(separator: ":").last ?? "") else { return }

        queue.async { [weak self, weak task] in
            guard let self, let task, self.process === task, !self.readinessCheckStarted else { return }
            self.currentPort = port
            self.readinessCheckStarted = true
            self.publish(.starting(port: port))
            self.waitUntilReady(port: port, attemptsRemaining: 80)
        }
    }

    private func failManagedProcess(message: String) {
        guard ownsProcess, let process, process.isRunning else {
            publish(.failed(port: currentPort, message: message))
            return
        }
        failureAfterTermination = message
        restartRequested = false
        stopping = true
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 4) { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            self.log("失败进程未在 4 秒内退出，结束 PID \(pid)。")
            kill(pid, SIGKILL)
        }
    }

    private func portIsOccupied(_ port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func publish(_ state: DSHServiceState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(state)
        }
    }

    private func log(_ message: String) {
        guard !message.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(line)
        }
        appendToDisk(line)
    }

    private func appendToDisk(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DeepSeek Harness GUI.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Logging must never prevent the GUI from starting.
        }
    }
}

final class StatusDotView: NSView {
    var color: NSColor = .systemGray {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

final class MainWindowController: NSWindowController, WKNavigationDelegate {
    private let service = DSHServiceController()
    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField(labelWithString: "正在检查…")
    private let portLabel = NSTextField(labelWithString: "localhost:\(defaultPort)")
    private let startButton = NSButton()
    private let stopButton = NSButton()
    private let restartButton = NSButton()
    private let refreshButton = NSButton()
    private let browserButton = NSButton()
    private let logsButton = NSButton()
    private let webView: WKWebView
    private let overlay = NSVisualEffectView()
    private let overlayTitle = NSTextField(labelWithString: "正在准备 DeepSeek Harness")
    private let overlayDetail = NSTextField(wrappingLabelWithString: "GUI 会自动复用现有服务，或在需要时启动 dsh。")
    private let logPanel = NSVisualEffectView()
    private let logTextView = NSTextView()
    private var logHeightConstraint: NSLayoutConstraint!
    private var logsVisible = false
    private var activePort = defaultPort

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness GUI"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 620)
        window.center()
        super.init(window: window)
        buildInterface()
        bindService()
        configureMenu()
        DispatchQueue.main.async { [weak self] in
            self?.service.bootstrap()
        }
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let toolbar = NSVisualEffectView()
        toolbar.material = .headerView
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        portLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        portLabel.textColor = .secondaryLabelColor

        configureButton(startButton, title: "启动", symbol: "play.fill", action: #selector(startService))
        configureButton(stopButton, title: "停止", symbol: "stop.fill", action: #selector(stopService))
        configureButton(restartButton, title: "重启", symbol: "arrow.clockwise", action: #selector(restartService))
        configureButton(refreshButton, title: "刷新", symbol: "arrow.triangle.2.circlepath", action: #selector(reloadPage))
        configureButton(browserButton, title: "浏览器打开", symbol: "safari", action: #selector(openInBrowser))
        configureButton(logsButton, title: "日志", symbol: "text.alignleft", action: #selector(toggleLogs))

        let statusStack = NSStackView(views: [statusDot, statusLabel, portLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbarStack = NSStackView(views: [
            statusStack, spacer, startButton, stopButton, restartButton,
            refreshButton, browserButton, logsButton
        ])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 8
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarStack)

        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        overlay.material = .contentBackground
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlayTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        overlayTitle.alignment = .center
        overlayDetail.textColor = .secondaryLabelColor
        overlayDetail.alignment = .center
        let overlayIcon = NSImageView(image: NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil) ?? NSImage())
        overlayIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        overlayIcon.contentTintColor = .systemBlue
        let overlayStack = NSStackView(views: [overlayIcon, overlayTitle, overlayDetail])
        overlayStack.orientation = .vertical
        overlayStack.alignment = .centerX
        overlayStack.spacing = 12
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(overlayStack)

        logPanel.material = .sidebar
        logPanel.blendingMode = .withinWindow
        logPanel.state = .active
        logPanel.translatesAutoresizingMaskIntoConstraints = false
        let logHeader = NSTextField(labelWithString: "运行日志 · ~/Library/Logs/DeepSeek Harness GUI.log")
        logHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        logHeader.textColor = .secondaryLabelColor
        logHeader.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.drawsBackground = false
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textColor = .secondaryLabelColor
        logTextView.textContainerInset = NSSize(width: 10, height: 8)
        scrollView.documentView = logTextView
        logPanel.addSubview(logHeader)
        logPanel.addSubview(scrollView)

        content.addSubview(toolbar)
        content.addSubview(webView)
        content.addSubview(overlay)
        content.addSubview(logPanel)

        logHeightConstraint = logPanel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 58),

            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 18),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: 8),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: logPanel.topAnchor),

            overlay.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: logPanel.topAnchor),
            overlayStack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            overlayStack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            overlayStack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            logPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            logPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            logPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            logHeightConstraint,

            logHeader.topAnchor.constraint(equalTo: logPanel.topAnchor, constant: 8),
            logHeader.leadingAnchor.constraint(equalTo: logPanel.leadingAnchor, constant: 14),
            logHeader.trailingAnchor.constraint(equalTo: logPanel.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: logHeader.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: logPanel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: logPanel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: logPanel.bottomAnchor)
        ])

        updateControls(for: .checking)
    }

    private func configureButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = action
    }

    private func bindService() {
        service.onStateChanged = { [weak self] state in
            self?.updateControls(for: state)
        }
        service.onLog = { [weak self] line in
            self?.appendLog(line)
        }
    }

    private func updateControls(for state: DSHServiceState) {
        switch state {
        case .checking:
            statusDot.color = .systemYellow
            statusLabel.stringValue = "检查服务"
            overlayTitle.stringValue = "正在检查 DeepSeek Harness"
            overlayDetail.stringValue = "如果 3080 端口已有 dsh，GUI 会直接复用。"
            overlay.isHidden = false
            setButtons(start: false, stop: false, restart: false, web: false)

        case let .starting(port):
            activePort = port
            statusDot.color = .systemYellow
            statusLabel.stringValue = "正在启动"
            portLabel.stringValue = port == 0 ? "自动分配端口" : "localhost:\(port)"
            overlayTitle.stringValue = "正在启动 dsh"
            overlayDetail.stringValue = "首次启动可能需要几秒钟。"
            overlay.isHidden = false
            setButtons(start: false, stop: true, restart: false, web: false)

        case let .running(port, owned):
            activePort = port
            statusDot.color = .systemGreen
            statusLabel.stringValue = owned ? "GUI 已启动" : "已连接现有服务"
            portLabel.stringValue = "localhost:\(port)"
            overlay.isHidden = true
            setButtons(start: false, stop: owned, restart: owned, web: true)
            loadHarness(port: port)

        case let .stopping(port):
            activePort = port
            statusDot.color = .systemOrange
            statusLabel.stringValue = "正在停止"
            overlayTitle.stringValue = "正在停止 dsh"
            overlayDetail.stringValue = "请稍候…"
            overlay.isHidden = false
            setButtons(start: false, stop: false, restart: false, web: false)

        case let .stopped(port):
            activePort = port
            statusDot.color = .systemGray
            statusLabel.stringValue = "已停止"
            overlayTitle.stringValue = "DeepSeek Harness 已停止"
            overlayDetail.stringValue = "点击“启动”即可重新运行。"
            overlay.isHidden = false
            setButtons(start: true, stop: false, restart: false, web: false)

        case let .failed(port, message):
            activePort = port
            statusDot.color = .systemRed
            statusLabel.stringValue = "启动失败"
            overlayTitle.stringValue = "DeepSeek Harness 暂不可用"
            overlayDetail.stringValue = message + "\n打开日志可查看详细信息。"
            overlay.isHidden = false
            setButtons(start: true, stop: false, restart: false, web: false)
        }
    }

    private func setButtons(start: Bool, stop: Bool, restart: Bool, web: Bool) {
        startButton.isEnabled = start
        stopButton.isEnabled = stop
        restartButton.isEnabled = restart
        refreshButton.isEnabled = web
        browserButton.isEnabled = web
    }

    private func loadHarness(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)/") else { return }
        if webView.url != url {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    private func appendLog(_ line: String) {
        let current = logTextView.string
        let combined = current.isEmpty ? line : current + "\n" + line
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        logTextView.string = lines.count > 3000 ? lines.suffix(3000).joined(separator: "\n") : combined
        logTextView.scrollToEndOfDocument(nil)
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 DeepSeek Harness GUI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let serviceItem = NSMenuItem()
        mainMenu.addItem(serviceItem)
        let serviceMenu = NSMenu(title: "服务")
        serviceItem.submenu = serviceMenu
        serviceItem.title = "服务"
        let reload = serviceMenu.addItem(withTitle: "刷新页面", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        let restart = serviceMenu.addItem(withTitle: "重启 dsh", action: #selector(restartService), keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command, .shift]
        restart.target = self
        let external = serviceMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser), keyEquivalent: "o")
        external.keyEquivalentModifierMask = [.command, .shift]
        external.target = self
        let logs = serviceMenu.addItem(withTitle: "显示或隐藏日志", action: #selector(toggleLogs), keyEquivalent: "l")
        logs.target = self
        NSApp.mainMenu = mainMenu
    }

    @objc private func startService() { service.start() }
    @objc private func stopService() { service.stop() }
    @objc private func restartService() { service.restart() }

    @objc func reloadPage() {
        if webView.url == nil { loadHarness(port: activePort) }
        else { webView.reload() }
    }

    @objc private func openInBrowser() {
        guard let url = URL(string: "http://localhost:\(activePort)/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLogs() {
        logsVisible.toggle()
        logHeightConstraint.constant = logsVisible ? 190 : 0
        logsButton.state = logsVisible ? .on : .off
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let localHosts = ["localhost", "127.0.0.1"]
        let isLocalDSH = url.scheme?.lowercased() == "http"
            && url.host.map(localHosts.contains) == true
            && (url.port ?? 80) == activePort
        if isLocalDSH {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        overlay.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        overlayTitle.stringValue = "页面加载失败"
        overlayDetail.stringValue = error.localizedDescription + "\n点击“刷新”重试。"
        overlay.isHidden = false
    }

    func shutdown() {
        service.terminateOwnedProcessOnExit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.shutdown()
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
