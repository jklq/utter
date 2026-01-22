import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import Security

// MARK: - App Support Directory
enum AppSupport {
    static let appName = "Utter"

    static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appName)
    }

    static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - Keychain Helper
final class KeychainHelper {
    static let serviceName = "com.utter.api"
    static let accountName = "groq-api-key"

    static func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // Delete existing item first
        deleteAPIKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Settings Storage
final class SettingsStorage {
    private static let polishTranscriptKey = "polishTranscript"

    static var polishTranscriptEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: polishTranscriptKey) }
        set { UserDefaults.standard.set(newValue, forKey: polishTranscriptKey) }
    }
}

// MARK: - Settings Window
class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class SettingsWindowController: NSWindowController {
    private var apiKeyField: NSTextField!
    private var polishCheckbox: NSButton!
    private var statusLabel: NSTextField!

    convenience init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Utter Settings"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // API Key Label
        let label = NSTextField(labelWithString: "Groq API Key:")
        label.frame = NSRect(x: 20, y: 135, width: 100, height: 20)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        contentView.addSubview(label)

        // API Key Input Field (secure - masked input)
        let secureField = NSSecureTextField(frame: NSRect(x: 20, y: 105, width: 340, height: 24))
        let hasExistingKey = KeychainHelper.getAPIKey() != nil
        secureField.placeholderString = hasExistingKey ? "API key saved • Enter new key to replace" : "Enter your Groq API key"
        secureField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        secureField.isBezeled = true
        secureField.bezelStyle = .roundedBezel
        apiKeyField = secureField
        contentView.addSubview(apiKeyField)

        // Polish Transcript Checkbox
        polishCheckbox = NSButton(checkboxWithTitle: "Polish transcript", target: self, action: #selector(polishSettingChanged))
        polishCheckbox.frame = NSRect(x: 20, y: 65, width: 340, height: 20)
        polishCheckbox.state = SettingsStorage.polishTranscriptEnabled ? .on : .off
        polishCheckbox.toolTip = "Clean up transcripts using AI before pasting"
        contentView.addSubview(polishCheckbox)

        // Status Label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 20, width: 200, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        // Save Button
        let saveButton = NSButton(frame: NSRect(x: 270, y: 15, width: 90, height: 30))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveAPIKey)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
    }

    @objc private func polishSettingChanged() {
        SettingsStorage.polishTranscriptEnabled = (polishCheckbox.state == .on)
    }

    @objc private func saveAPIKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExistingKey = KeychainHelper.getAPIKey() != nil

        // If field is empty, just close if we already have a key saved
        if key.isEmpty {
            if hasExistingKey {
                window?.close()
            } else {
                statusLabel.stringValue = "API key cannot be empty"
                statusLabel.textColor = .systemRed
            }
            return
        }

        // Validate API key format (Groq keys start with gsk_)
        if !key.hasPrefix("gsk_") {
            statusLabel.stringValue = "Invalid key format (should start with gsk_)"
            statusLabel.textColor = .systemRed
            return
        }

        if KeychainHelper.saveAPIKey(key) {
            statusLabel.stringValue = "Saved to Keychain"
            statusLabel.textColor = .systemGreen

            // Post notification that API key changed
            NotificationCenter.default.post(name: .apiKeyDidChange, object: nil)

            // Close window after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.window?.close()
            }
        } else {
            statusLabel.stringValue = "Failed to save"
            statusLabel.textColor = .systemRed
        }
    }

    func showWindow() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(apiKeyField)
    }
}

// Notification for API key changes
extension Notification.Name {
    static let apiKeyDidChange = Notification.Name("apiKeyDidChange")
}

// MARK: - Overlay Window
class OverlayWindow: NSWindow {
    // Window dimensions (fixed at max size to accommodate all states)
    private let windowWidth: CGFloat = 160
    private let windowHeight: CGFloat = 36

    // Distance above the dock
    private let dockOffset: CGFloat = 4

    // Pill dimensions for each state
    private let deactivatedSize = CGSize(width: 40, height: 9)
    private let activatedSize = CGSize(width: 100, height: 32)

    // Layout constants
    private let barsLeftEdge: CGFloat = 42  // Bars position within window (centered in activated pill)

    private var visualEffect: NSVisualEffectView!
    private var backgroundLayer: CALayer!
    private var barsView: NSView!
    private var barLayers: [CALayer] = []
    private let barCount = 12
    private let barWidth: CGFloat = 3.5
    private let barSpacing: CGFloat = 3
    private let barMinHeight: CGFloat = 4
    private let barMaxHeight: CGFloat = 20

    // Breathing animation for processing state
    private var breathingTimer: Timer?
    private var breathingPhase: Double = 0
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupPosition()
        startObservingScreenChanges()
        
        // Container view that fills the window
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = containerView
        
        // The actual pill view
        let startFrame = frameFor(size: deactivatedSize)
        visualEffect = NSVisualEffectView(frame: startFrame)
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = deactivatedSize.height / 2
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true

        // Background layer for opacity control
        backgroundLayer = CALayer()
        backgroundLayer.frame = visualEffect.bounds
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        backgroundLayer.cornerRadius = deactivatedSize.height / 2
        backgroundLayer.cornerCurve = .continuous
        visualEffect.layer?.insertSublayer(backgroundLayer, at: 0)

        // Deactivated state: semi-bright border
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        visualEffect.layer?.borderWidth = 1

        containerView.addSubview(visualEffect)

        // Create audio visualization bars (hidden initially)
        setupBars()
    }

    private func setupBars() {
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let containerHeight = barMaxHeight

        // Bars positioned at fixed location (left of center to leave room for spinner)
        barsView = NSView(frame: CGRect(
            x: barsLeftEdge,
            y: (windowHeight - containerHeight) / 2,
            width: totalWidth,
            height: containerHeight
        ))
        barsView.wantsLayer = true
        barsView.alphaValue = 0
        contentView?.addSubview(barsView)

        // Bars positioned within container, growing from center
        for i in 0..<barCount {
            let bar = CALayer()
            let x = CGFloat(i) * (barWidth + barSpacing)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barMinHeight)
            bar.position = CGPoint(x: x + barWidth / 2, y: containerHeight / 2)
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = barWidth / 2
            barsView.layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    func updateBars(levels: [CGFloat]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (i, bar) in barLayers.enumerated() {
            let level = i < levels.count ? levels[i] : 0
            let height = barMinHeight + (barMaxHeight - barMinHeight) * level
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
        }

        CATransaction.commit()
    }

    func showBars() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            barsView.animator().alphaValue = 1
        }
    }

    func hideBars() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            barsView.animator().alphaValue = 0
        }

        // Reset bar heights
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barMinHeight)
        }
        CATransaction.commit()
    }

    func startBreathing() {
        // Invalidate any existing timer first to prevent leaks
        breathingTimer?.invalidate()

        // Start a gentle breathing animation on the bars
        breathingPhase = 0
        breathingTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.breathingPhase += 1.0/30.0
                
                var levels: [CGFloat] = []
                for i in 0..<self.barCount {
                    let barIndex = Double(i)
                    let centerIndex = Double(self.barCount - 1) / 2.0
                    
                    // Slow, gentle wave pattern
                    let wave = sin(self.breathingPhase * 2.0 + barIndex * 0.4) * 0.15 + 0.25
                    
                    // Center bars slightly higher
                    let centerBias = 1.0 - abs(barIndex - centerIndex) / centerIndex * 0.3
                    
                    let level = CGFloat(wave * centerBias)
                    levels.append(max(0.1, min(0.5, level)))
                }
                
                self.updateBars(levels: levels)
            }
        }
    }
    
    func stopBreathing() {
        breathingTimer?.invalidate()
        breathingTimer = nil
    }

    func showProcessing() {
        // Change border to yellow while keeping same size as activated state
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0.2, 1)
            context.allowsImplicitAnimation = true

            // Yellow border for processing
            self.visualEffect.layer?.borderColor = NSColor.systemYellow.cgColor
            self.visualEffect.layer?.borderWidth = 2
        }
    }

    private func frameFor(size: CGSize) -> NSRect {
        let x = (windowWidth - size.width) / 2
        let y = (windowHeight - size.height) / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func setupPosition() {
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let x = visibleFrame.midX - (windowWidth / 2)
            // Position just above the dock
            let y = visibleFrame.minY + dockOffset
            self.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
        }
    }

    private func startObservingScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenDidChange(_ notification: Notification) {
        setupPosition()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Timer cleanup: stopBreathing() is called by AppDelegate before window deallocation
        // (in onProcessingComplete callback). Direct access here causes Swift 6 concurrency errors.
    }
    
    func expand() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0.2, 1)
            context.allowsImplicitAnimation = true

            let targetFrame = frameFor(size: activatedSize)
            self.visualEffect.animator().frame = targetFrame
            self.visualEffect.layer?.cornerRadius = self.activatedSize.height / 2

            // Update background layer
            self.backgroundLayer.frame = CGRect(origin: .zero, size: self.activatedSize)
            self.backgroundLayer.cornerRadius = self.activatedSize.height / 2
            self.backgroundLayer.backgroundColor = NSColor.black.cgColor

            self.visualEffect.layer?.borderColor = NSColor.red.cgColor
            self.visualEffect.layer?.borderWidth = 2
        }
    }

    func contract() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            context.allowsImplicitAnimation = true

            let targetFrame = frameFor(size: deactivatedSize)
            self.visualEffect.animator().frame = targetFrame
            self.visualEffect.layer?.cornerRadius = self.deactivatedSize.height / 2

            // Update background layer
            self.backgroundLayer.frame = CGRect(origin: .zero, size: self.deactivatedSize)
            self.backgroundLayer.cornerRadius = self.deactivatedSize.height / 2
            self.backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor

            // Semi-bright border for deactivated
            self.visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
            self.visualEffect.layer?.borderWidth = 1
        }
    }
}

// MARK: - Data Extension for safe multipart body building
private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

// MARK: - Groq Client
final class GroqClient: @unchecked Sendable {
    private static let transcriptionEndpointURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")
    private static let chatEndpointURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")

    private var transcriptionEndpoint: URL {
        Self.transcriptionEndpointURL ?? URL(string: "https://api.groq.com")!
    }

    private var chatEndpoint: URL {
        Self.chatEndpointURL ?? URL(string: "https://api.groq.com")!
    }

    var onTranscription: ((String) -> Void)?
    var onError: (() -> Void)?
    var onMissingAPIKey: (() -> Void)?

    func transcribe(audioData: Data) {
        guard let apiKey = KeychainHelper.getAPIKey(), !apiKey.isEmpty else {
            print("No API key configured. Please set it in Settings.")
            onMissingAPIKey?()
            onError?()
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: transcriptionEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add file field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        body.appendString("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        // Add model field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("whisper-large-v3\r\n")

        // Add language field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        body.appendString("en\r\n")

        body.appendString("--\(boundary)--\r\n")

        request.httpBody = body

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)

        session.dataTask(with: request) { [weak self] data, response, error in
            if error != nil {
                self?.onError?()
                return
            }

            // Check HTTP response status code
            guard let httpResponse = response as? HTTPURLResponse else {
                self?.onError?()
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                // Try to extract error message from response
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorInfo = json["error"] as? [String: Any],
                   let message = errorInfo["message"] as? String {
                    print("Groq API error (\(httpResponse.statusCode)): \(message)")
                } else {
                    print("Groq API error: HTTP \(httpResponse.statusCode)")
                }
                self?.onError?()
                return
            }

            guard let data = data else {
                self?.onError?()
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    self?.onTranscription?(text)
                } else {
                    self?.onError?()
                }
            } catch {
                self?.onError?()
            }
        }.resume()
    }

    func polishTranscript(_ text: String, completion: @escaping (String?) -> Void) {
        guard let apiKey = KeychainHelper.getAPIKey(), !apiKey.isEmpty else {
            print("No API key configured for polishing.")
            completion(nil)
            return
        }

        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
            You are a transcript polisher for voice dictation. Your task is to clean up speech-to-text transcripts and interpret dictation commands.

            Dictation commands to interpret:
            - "quote" / "end quote" or "unquote": Wrap the content between them in quotation marks
            - "new line" or "newline": Insert a line break
            - "new paragraph": Insert two line breaks
            - "period", "comma", "question mark", "exclamation point/mark": Insert that punctuation
            - Corrections like "no I mean", "I meant", "actually", "scratch that", "delete that": Discard what came before and use only the corrected version

            Rules:
            - Process dictation commands as described above
            - When the user makes a correction, use ONLY their final intended version
            - Fix obvious transcription errors (misheard words, missing punctuation)
            - Correct grammar and spelling mistakes
            - Keep the intended phrasing - do not rewrite beyond what's needed
            - Output only the final clean text, nothing else

            Example: "quote How are you question mark No I mean how am I question mark end quote" → "How am I?"
            """

        let requestBody: [String: Any] = [
            "model": "openai/gpt-oss-120b",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            print("Failed to serialize polish request: \(error)")
            completion(nil)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Polish request failed: \(error)")
                completion(nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorInfo = json["error"] as? [String: Any],
                   let message = errorInfo["message"] as? String {
                    print("Groq polish API error (\(httpResponse.statusCode)): \(message)")
                } else {
                    print("Groq polish API error: HTTP \(httpResponse.statusCode)")
                }
                completion(nil)
                return
            }

            guard let data = data else {
                completion(nil)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    print("Failed to parse polish response")
                    completion(nil)
                }
            } catch {
                print("Failed to decode polish response: \(error)")
                completion(nil)
            }
        }.resume()
    }
}

// MARK: - Text Inputter
final class TextInputter {
    static func pasteText(_ text: String) {
        // Copy text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Delay to ensure clipboard is ready and Fn key is fully released
        usleep(100000)  // 100ms

        // Simulate Cmd+V to paste using CGEvent
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        // Key down for 'V' with Command modifier
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) else {
            return
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)

        // Small delay between key down and key up
        usleep(10000)  // 10ms

        // Key up for 'V'
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return
        }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: - Audio Recorder
@MainActor
final class AudioCapture: NSObject {
    var recorder: AVAudioRecorder?
    var tempURL: URL?
    let groqClient = GroqClient()
    private var meterTimer: Timer?
    var onAudioLevels: (([CGFloat]) -> Void)?
    var onTranscription: ((String) -> Void)?
    var onProcessingStart: (() -> Void)?
    var onProcessingComplete: (() -> Void)?

    // For smoothing and generating bar levels
    private var previousLevels: [CGFloat] = []
    private let barCount = 12

    override init() {
        super.init()
        previousLevels = Array(repeating: 0, count: barCount)
        setupRecorder()
        groqClient.onTranscription = { [weak self] text in
            guard let self = self else { return }

            // Check if polishing is enabled
            if SettingsStorage.polishTranscriptEnabled {
                self.groqClient.polishTranscript(text) { polishedText in
                    DispatchQueue.main.async {
                        self.cleanupTempFile()
                        // Use polished text if available, otherwise fall back to original
                        self.onTranscription?(polishedText ?? text)
                        self.onProcessingComplete?()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.cleanupTempFile()
                    self.onTranscription?(text)
                    self.onProcessingComplete?()
                }
            }
        }
        groqClient.onError = { [weak self] in
            DispatchQueue.main.async {
                self?.cleanupTempFile()
                self?.onProcessingComplete?()
            }
        }
    }

    private func cleanupTempFile() {
        guard let url = tempURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func setupRecorder() {
        AppSupport.ensureDirectoryExists()
        let recordingURL = AppSupport.directory.appendingPathComponent("recording.m4a")
        tempURL = recordingURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.prepareToRecord()
        } catch {
            print("Failed to set up recorder: \(error)")
        }
    }

    func start() {
        setupRecorder()
        recorder?.record()
        startMetering()
    }

    private func startMetering() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMeters()
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeters() {
        guard let recorder = recorder, recorder.isRecording else { return }
        recorder.updateMeters()

        let power = recorder.averagePower(forChannel: 0)

        // Convert dB to linear scale (0 to 1)
        let minDb: Float = -45
        let maxDb: Float = -10
        let audioLevel = max(0, min(1, (power - minDb) / (maxDb - minDb)))

        let time = Date().timeIntervalSinceReferenceDate

        var levels: [CGFloat] = []
        for i in 0..<barCount {
            let barIndex = Double(i)
            let centerIndex = Double(barCount - 1) / 2.0

            // Organic wave pattern per bar
            let wave1 = sin(time * 4.0 + barIndex * 0.9) * 0.35
            let wave2 = sin(time * 6.5 - barIndex * 0.6) * 0.25
            let wave3 = sin(time * 9.0 + barIndex * 1.1) * 0.2

            // Center bars higher, edges lower
            let centerBias = 1.0 - abs(barIndex - centerIndex) / centerIndex * 0.25

            // Combine waves, scale by audio level
            let wavePattern = (0.6 + wave1 + wave2 + wave3) * centerBias
            let barLevel = CGFloat(audioLevel) * CGFloat(wavePattern)

            // Smooth with previous - fast attack, slower decay
            let attackDecay = barLevel > previousLevels[i] ? 0.8 : 0.5
            let smoothed = previousLevels[i] * (1 - attackDecay) + barLevel * attackDecay
            levels.append(max(0, min(1, smoothed)))
        }

        previousLevels = levels
        onAudioLevels?(levels)
    }

    func stop() {
        stopMetering()
        recorder?.stop()

        guard let url = tempURL else { return }

        onProcessingStart?()
        let client = groqClient

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: url)
                print("Sending \(data.count) bytes to Groq...")
                client.transcribe(audioData: data)
            } catch {
                print("Failed to read audio file: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.onProcessingComplete?()
                }
            }
        }
    }
}

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private static var didLaunch = false

    private var window: OverlayWindow?
    private var audioCapture: AudioCapture?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var isFnPressed = false
    private var showBarsWorkItem: DispatchWorkItem?

    // Menu bar
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print(">>> applicationDidFinishLaunching called, PID: \(ProcessInfo.processInfo.processIdentifier)")

        guard !Self.didLaunch else {
            print(">>> Already launched, skipping")
            return
        }
        Self.didLaunch = true

        // Setup main menu with Edit menu for keyboard shortcuts
        setupMainMenu()

        // Setup menu bar icon
        setupStatusBar()

        let overlayWindow = OverlayWindow()
        window = overlayWindow
        overlayWindow.orderFrontRegardless()

        let capture = AudioCapture()
        audioCapture = capture

        // Connect audio levels to window visualization
        capture.onAudioLevels = { [weak self] levels in
            DispatchQueue.main.async {
                self?.window?.updateBars(levels: levels)
            }
        }

        // Handle transcriptions - paste into active application
        capture.onTranscription = { text in
            // Dispatch async to ensure UI event loop has processed Fn key release
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                TextInputter.pasteText(text)
            }
        }

        // Handle processing state
        capture.onProcessingStart = { [weak self] in
            self?.window?.showProcessing()
            self?.window?.startBreathing()
        }

        capture.onProcessingComplete = { [weak self] in
            self?.window?.stopBreathing()
            self?.window?.hideBars()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self?.window?.contract()
            }
        }

        // Handle missing API key - open settings
        capture.groqClient.onMissingAPIKey = { [weak self] in
            DispatchQueue.main.async {
                self?.openSettings()
            }
        }

        // Check permissions
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessEnabled {
            print("WARNING: Accessibility permissions needed for global key monitoring. Please grant access in System Settings -> Privacy & Security -> Accessibility.")
        }

        // Monitor flags changed (for modifiers like Fn)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Also need local monitor if the app happens to be frontmost
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // Show settings on first launch if no API key
        if KeychainHelper.getAPIKey() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings()
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (required but can be minimal)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu - enables Cmd+C, Cmd+V, Cmd+A, Cmd+X in text fields
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusBar() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            // Use SF Symbol for microphone
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Utter") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "W"
            }
        }
    
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Utter", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    @objc func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove event monitors to prevent leaks
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }

        // Explicitly remove status item to prevent ghost icons
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        // .function is the bitmask for the Fn key
        let isFnNow = flags.contains(.function)

        if isFnNow && !isFnPressed {
            // Pressed
            isFnPressed = true
            DispatchQueue.main.async { [weak self] in
                self?.window?.expand()
                self?.audioCapture?.start()
                // Show bars after pill has expanded
                self?.showBarsWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.window?.showBars()
                }
                self?.showBarsWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
            }
        } else if !isFnNow && isFnPressed {
            // Released
            isFnPressed = false
            // Cancel pending showBars if released quickly
            showBarsWorkItem?.cancel()
            showBarsWorkItem = nil
            DispatchQueue.main.async { [weak self] in
                self?.audioCapture?.stop()
            }
        }
    }
}

// MARK: - Single Instance Enforcement
/// Ensures only one instance of the app runs at a time using a file lock.
/// If another instance holds the lock, this instance exits immediately.
func ensureSingleInstance() -> Int32 {
    AppSupport.ensureDirectoryExists()
    let lockPath = AppSupport.directory.appendingPathComponent("utter.lock").path
    let lockFile = open(lockPath, O_CREAT | O_RDWR, 0o600)

    guard lockFile >= 0 else {
        print(">>> Warning: Could not open lock file")
        return lockFile
    }

    // Try to acquire exclusive lock (non-blocking)
    if flock(lockFile, LOCK_EX | LOCK_NB) != 0 {
        // Another instance has the lock - exit
        print(">>> Another instance is already running, exiting")
        close(lockFile)
        exit(0)
    }

    // Write our PID to the lock file (for debugging)
    let pid = ProcessInfo.processInfo.processIdentifier
    ftruncate(lockFile, 0)
    let pidString = "\(pid)\n"
    pidString.withCString { ptr in
        _ = write(lockFile, ptr, strlen(ptr))
    }

    print(">>> Acquired lock, PID: \(pid)")

    // Keep lock file open - it will be released when process exits
    return lockFile
}

// Global lock file descriptor - keep open for lifetime of process
let lockFD = ensureSingleInstance()

// MARK: - Main
print(">>> Main starting, PID: \(ProcessInfo.processInfo.processIdentifier)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Run as menu bar app (no dock icon)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

