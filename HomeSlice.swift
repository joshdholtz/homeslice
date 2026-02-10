import AppKit
import SwiftUI
import Combine
import CryptoKit
import Security

// MARK: - Pizza State

enum PizzaMood: String, CaseIterable {
    case happy = "Happy"
    case excited = "Excited"
    case sleepy = "Sleepy"
    case love = "Love"
    case surprised = "Surprised"
}

// Single struct for chat display state - enables atomic updates
struct ChatDisplayState: Equatable {
    var isThinking: Bool = false
    var showResponse: Bool = false
    var botResponse: String = ""
    var bubbleOnLeft: Bool = false  // Position bubble based on pizza location
}

// Chat message for history
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date
}

class PizzaState: ObservableObject {
    static let shared = PizzaState()
    @Published var mood: PizzaMood = .happy
    @Published var isVisible: Bool = true
    @Published var showParticles: Bool = false
    @Published var particleType: ParticleType = .hearts

    // Chat state - single published property for atomic updates
    @Published var showChatInput: Bool = false
    @Published var chatMessage: String = ""
    @Published var chatDisplay: ChatDisplayState = ChatDisplayState()

    // Active app tracking
    @Published var currentApp: String = ""
    var recentApps: [(app: String, timestamp: Date)] = []
    private let maxRecentApps = 20

    // Chat history
    @Published var chatHistory: [ChatMessage] = []
    private let maxHistoryMessages = 50

    // Bot configuration (stored in UserDefaults)
    @Published var botURL: String {
        didSet {
            UserDefaults.standard.set(botURL, forKey: "botURL")
        }
    }

    @Published var botToken: String {
        didSet {
            UserDefaults.standard.set(botToken, forKey: "botToken")
        }
    }

    init() {
        self.botURL = UserDefaults.standard.string(forKey: "botURL") ?? ""
        self.botToken = UserDefaults.standard.string(forKey: "botToken") ?? ""
        setupAppMonitoring()
    }

    private func setupAppMonitoring() {
        // Get initial app
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
            currentApp = app
        }

        // Monitor app changes
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let appName = app.localizedName else { return }

            // Skip if same app or if it's HomeSlice itself
            guard appName != self.currentApp, appName != "HomeSlice" else { return }

            let previousApp = self.currentApp

            // Update current and add to history
            self.currentApp = appName
            self.recentApps.append((app: appName, timestamp: Date()))

            // Keep only recent entries
            if self.recentApps.count > self.maxRecentApps {
                self.recentApps.removeFirst()
            }

            print(">>> App changed to: \(appName)")

            // Send activity update to bot
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            GatewayClient.shared.sendActivityUpdate("[\(timestamp)] Switched from \(previousApp) to \(appName)")
        }
    }

    func addToHistory(role: String, content: String) {
        let message = ChatMessage(role: role, content: content, timestamp: Date())
        chatHistory.append(message)
        if chatHistory.count > maxHistoryMessages {
            chatHistory.removeFirst()
        }
    }

    func getAppContext() -> String {
        var context = "Current app: \(currentApp)"
        if recentApps.count > 1 {
            // Show last 10 with timestamps
            let formatter = DateFormatter()
            formatter.timeStyle = .short

            let recent = recentApps.suffix(10).map {
                "\(formatter.string(from: $0.timestamp)) \($0.app)"
            }.joined(separator: " → ")
            context += "\nRecent activity: \(recent)"
            context += "\nTotal switches this session: \(recentApps.count)"
        }
        return context
    }

    func sendMessage() {
        guard !chatMessage.isEmpty, !botURL.isEmpty else { return }

        let message = chatMessage
        chatMessage = ""
        showChatInput = false

        // Add user message to history
        addToHistory(role: "user", content: message)

        // Single atomic update to start thinking
        chatDisplay = ChatDisplayState(isThinking: true, showResponse: false, botResponse: "")
        mood = .excited

        GatewayClient.shared.send(message: message, to: botURL, token: botToken) { [weak self] response in
            print(">>> Completion handler called")
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let response = response {
                    // Force UTF8 encoding, no truncation - bubble is scrollable
                    let utf8Data = response.data(using: .utf8) ?? Data()
                    let utf8String = String(data: utf8Data, encoding: .utf8) ?? "Got it!"
                    print(">>> Response (len=\(utf8String.count))")

                    // Add bot response to history
                    self.addToHistory(role: "assistant", content: utf8String)

                    // Check if pizza is on right side of screen -> bubble on left
                    var bubbleOnLeft = false
                    if let appDelegate = NSApp.delegate as? AppDelegate,
                       let screen = NSScreen.main {
                        let panelX = appDelegate.panel.frame.midX
                        bubbleOnLeft = panelX > screen.frame.midX
                    }

                    self.chatDisplay = ChatDisplayState(
                        isThinking: false,
                        showResponse: true,
                        botResponse: utf8String,
                        bubbleOnLeft: bubbleOnLeft
                    )
                    self.mood = .happy

                    // Hide response after 10 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        print(">>> Hiding response after timeout")
                        self.chatDisplay = ChatDisplayState(isThinking: false, showResponse: false, botResponse: "")
                    }
                } else {
                    // Single atomic update for error
                    self.chatDisplay = ChatDisplayState(
                        isThinking: false,
                        showResponse: true,
                        botResponse: "Couldn't reach bot!"
                    )
                    self.mood = .surprised

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.chatDisplay = ChatDisplayState(isThinking: false, showResponse: false, botResponse: "")
                        self.mood = .happy
                    }
                }
            }
        }
    }
}

enum ParticleType {
    case hearts
    case sparkles
    case stars
}

// MARK: - Device Identity (Ed25519 keypair in Keychain)

class DeviceIdentity {
    static let shared = DeviceIdentity()

    private let privateKeyTag = "homeslice.device.privateKey"
    private var _privateKey: Curve25519.Signing.PrivateKey?

    var privateKey: Curve25519.Signing.PrivateKey {
        if let key = _privateKey { return key }

        // Try to load from Keychain
        if let keyData = loadFromKeychain(tag: privateKeyTag),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            _privateKey = key
            print("Loaded existing keypair from Keychain")
            return key
        }

        // Generate new key and store it
        let newKey = Curve25519.Signing.PrivateKey()
        saveToKeychain(tag: privateKeyTag, data: newKey.rawRepresentation)
        _privateKey = newKey
        print("Generated new keypair and saved to Keychain")
        return newKey
    }

    // Device ID is SHA256 hash of public key (64-char lowercase hex)
    var deviceId: String {
        let pubKeyData = Data(privateKey.publicKey.rawRepresentation)
        let hash = SHA256.hash(data: pubKeyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    var publicKeyBase64: String {
        Data(privateKey.publicKey.rawRepresentation).base64EncodedString()
    }

    /// Sign the connect attestation string (v2 format)
    /// Format: v2|deviceId|clientId|clientMode|role|scopesCSV|signedAtMs|token|nonce
    func signConnectAttestation(
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAt: Int64,
        token: String,
        nonce: String
    ) -> String {
        let scopesCSV = scopes.joined(separator: ",")
        let attestation = "v2|\(deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopesCSV)|\(signedAt)|\(token)|\(nonce)"

        print("=== Attestation String ===")
        print(attestation)
        print("==========================")

        guard let attestationData = attestation.data(using: .utf8) else {
            print("Failed to encode attestation as UTF-8")
            return ""
        }

        guard let signature = try? privateKey.signature(for: attestationData) else {
            print("Failed to sign attestation")
            return ""
        }

        let sigData = Data(signature)
        let sig = sigData.base64EncodedString()

        // Sanity checks
        print("Signature length: \(sigData.count) bytes (expected: 64)")

        // Verify signature locally before returning
        let isValid = privateKey.publicKey.isValidSignature(signature, for: attestationData)
        print("Signature verification: \(isValid ? "VALID" : "INVALID")")

        return sig
    }

    // Debug: print identity info with sanity checks
    func printDebugInfo() {
        let id = deviceId
        let pubKey = publicKeyBase64

        print("=== Device Identity ===")
        print("Device ID: \(id)")
        print("  - Length: \(id.count) (expected: 64)")
        print("  - Hex valid: \(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)")

        print("Public Key: \(pubKey)")
        if let decoded = Data(base64Encoded: pubKey) {
            print("  - Decoded length: \(decoded.count) bytes (expected: 32)")
        } else {
            print("  - ERROR: Invalid base64")
        }
        print("=======================")
    }

    private func saveToKeychain(tag: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        print("Keychain save status: \(status == errSecSuccess ? "success" : "failed (\(status))")")
    }

    private func loadFromKeychain(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    // Reset identity (for debugging - generates fresh keypair)
    func resetIdentity() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: privateKeyTag
        ]
        SecItemDelete(query as CFDictionary)
        _privateKey = nil
        print("Identity reset - will generate new keypair on next access")
    }
}

// MARK: - Gateway WebSocket Client

class GatewayClient {
    static let shared = GatewayClient()

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var completion: ((String?) -> Void)?
    private var currentRunId: String?
    private var responseBuffer: String = ""
    private var challengeNonce: String?
    private var challengeTs: Int64?
    private var isConnected = false
    private var pendingMessage: String?
    private var gatewayURL: String = ""
    private var gatewayToken: String = ""
    private var requestId = 0

    // Session management
    private let pizzaSessionKey = "app:pizza:main"
    private let activitySessionKey = "app:pizza:activity"
    private var activitySessionInitialized = false

    func send(message: String, to url: String, token: String, completion: @escaping (String?) -> Void) {
        self.completion = completion
        self.pendingMessage = message
        self.gatewayURL = url
        self.gatewayToken = token
        self.responseBuffer = ""

        if isConnected {
            sendChatMessage(message)
        } else {
            connect()
        }
    }

    private func connect() {
        // Convert https:// to wss://
        var wsURL = gatewayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if wsURL.hasPrefix("https://") {
            wsURL = "wss://" + String(wsURL.dropFirst(8))
        } else if wsURL.hasPrefix("http://") {
            wsURL = "ws://" + String(wsURL.dropFirst(7))
        } else if !wsURL.hasPrefix("wss://") && !wsURL.hasPrefix("ws://") {
            wsURL = "wss://" + wsURL
        }

        print("Connecting to WebSocket: \(wsURL)")

        guard let url = URL(string: wsURL) else {
            print("Invalid WebSocket URL: \(wsURL)")
            completion?(nil)
            return
        }

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue.main)
        webSocket = session?.webSocketTask(with: url)

        // Send a ping to test connection
        webSocket?.sendPing { [weak self] error in
            if let error = error {
                print("WebSocket ping failed: \(error.localizedDescription)")
                self?.completion?(nil)
            } else {
                print("WebSocket connected successfully!")
            }
        }

        webSocket?.resume()
        receiveMessage()
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            // Ensure we're on main thread for all handling
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveMessage()  // Keep listening

                case .failure(let error):
                    print("WebSocket receive error: \(error.localizedDescription)")
                    self.isConnected = false
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        print("Received: \(text.prefix(200))...")

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Failed to parse JSON")
            return
        }

        let type = json["type"] as? String ?? ""
        print("Message type: \(type)")

        switch type {
        case "event":
            handleEvent(json)
        case "res":
            handleResponse(json)
        default:
            print("Unknown message type: \(type)")
            break
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        let event = json["event"] as? String ?? ""
        let payload = json["payload"] as? [String: Any] ?? [:]
        print("Event: \(event)")

        switch event {
        case "connect.challenge":
            print("Got challenge, sending connect request...")
            challengeNonce = payload["nonce"] as? String
            challengeTs = payload["ts"] as? Int64
            sendConnectRequest()

        case "chat":
            // Only process events from our pizza sessions (not main web session)
            let sessionKey = payload["sessionKey"] as? String ?? ""
            guard sessionKey.hasPrefix("app:pizza:") || sessionKey.hasPrefix("agent:main:app:pizza:") else {
                return
            }

            // Extract assistant message content
            if let message = payload["message"] as? [String: Any],
               let role = message["role"] as? String, role == "assistant",
               let content = message["content"] as? [[String: Any]] {
                // Content is an array of content blocks
                for block in content {
                    if let type = block["type"] as? String, type == "text",
                       let text = block["text"] as? String {
                        responseBuffer = text
                    }
                }
            }
            // Check for completion (state: "final")
            if let state = payload["state"] as? String, state == "final" {
                print("Chat completed with response: \(responseBuffer.prefix(50))...")
                finishWithResponse()
            }

        case "agent":
            // Only process events from our pizza sessions
            let sessionKey = payload["sessionKey"] as? String ?? ""
            guard sessionKey.hasPrefix("agent:main:app:pizza:") else {
                return
            }

            // Check if this is from activity session
            let isActivitySession = sessionKey.contains("activity")

            // Capture streaming text from assistant
            if let stream = payload["stream"] as? String, stream == "assistant",
               let data = payload["data"] as? [String: Any],
               let text = data["text"] as? String {
                responseBuffer = text  // text is accumulated, not delta
            }

            // Check for run completion
            if let data = payload["data"] as? [String: Any],
               let phase = data["phase"] as? String, phase == "end" {
                print(">>> Agent ended, delivering response")

                // For activity session, only show if it's not just an acknowledgment
                if isActivitySession {
                    let response = responseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if response.count > 5 && !response.hasPrefix("📝") {
                        // Bot has something to say! Show it
                        showActivityNudge(response)
                    }
                    responseBuffer = ""
                } else {
                    finishWithResponse()
                }
            }

        default:
            break
        }
    }

    private func handleResponse(_ json: [String: Any]) {
        let ok = json["ok"] as? Bool ?? false
        let id = json["id"] as? String ?? ""
        let payload = json["payload"] as? [String: Any] ?? [:]

        if id == "1" {
            // Connect response
            if ok {
                isConnected = true
                if let msg = pendingMessage {
                    pendingMessage = nil
                    sendChatMessage(msg)
                }
            } else {
                let error = payload["error"] as? String ?? "Connection failed"
                print("Connect failed: \(error)")
                completion?(nil)
            }
        } else if id == "2" {
            // chat.send response
            if ok {
                currentRunId = payload["runId"] as? String
                // Wait for events to get the actual response
            }
        }
    }

    private func sendConnectRequest() {
        guard let nonce = challengeNonce, let ts = challengeTs else {
            print("Missing challenge nonce or timestamp")
            return
        }

        let device = DeviceIdentity.shared
        device.printDebugInfo()

        // These must match EXACTLY what we send in the connect params
        let clientId = "cli"
        let clientMode = "cli"
        let role = "operator"
        let scopes = ["operator.read", "operator.write"]
        let signedAt = ts  // Use challenge timestamp

        // Sign the full attestation string (v2 format)
        let signature = device.signConnectAttestation(
            clientId: clientId,
            clientMode: clientMode,
            role: role,
            scopes: scopes,
            signedAt: signedAt,
            token: gatewayToken,
            nonce: nonce
        )

        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": clientId,
                "displayName": "HomeSlice",
                "version": "1.0.0",
                "platform": "macos",
                "mode": clientMode
            ] as [String: Any],
            "role": role,
            "scopes": scopes,
            "caps": [],
            "commands": [],
            "permissions": [:] as [String: Any],
            "locale": "en-US",
            "userAgent": "HomeSlice/1.0.0",
            "device": [
                "id": device.deviceId,
                "publicKey": device.publicKeyBase64,
                "signature": signature,
                "signedAt": signedAt,
                "nonce": nonce
            ] as [String: Any]
        ]

        // Add auth token if provided
        if !gatewayToken.isEmpty {
            params["auth"] = ["token": gatewayToken]
        }

        sendRequest(id: "1", method: "connect", params: params)
    }

    private func sendChatMessage(_ message: String) {
        // Include app context and concise mode
        let appContext = PizzaState.shared.getAppContext()
        let prefixedMessage = "[CONCISE: 1-3 sentences max]\n[\(appContext)]\n\(message)"

        let params: [String: Any] = [
            "sessionKey": pizzaSessionKey,
            "message": prefixedMessage,
            "idempotencyKey": UUID().uuidString
        ]
        sendRequest(id: "2", method: "chat.send", params: params)
    }

    private var activityBuffer: [String] = []
    private var lastActivitySend: Date = .distantPast

    func sendActivityUpdate(_ activity: String) {
        guard isConnected else { return }

        // Buffer activities and send every 5 minutes
        activityBuffer.append(activity)

        let timeSinceLastSend = Date().timeIntervalSince(lastActivitySend)
        guard timeSinceLastSend > 300 else { return }  // 5 minutes

        // Initialize activity session with instructions on first use
        if !activitySessionInitialized {
            activitySessionInitialized = true
            let initMessage = """
            You are a quiet activity logger for a desktop companion. Your job:
            1. Silently log app usage - the user switches apps A LOT for work, that's normal
            2. Just respond with "📝" for ALL activity updates
            3. ONLY speak up if asked directly about activity
            4. NEVER interrupt or nudge about app switching - it's their job
            """
            let initParams: [String: Any] = [
                "sessionKey": activitySessionKey,
                "message": initMessage,
                "idempotencyKey": UUID().uuidString
            ]
            sendRequest(id: "activity-init", method: "chat.send", params: initParams)
        }

        // Send batched activity summary
        lastActivitySend = Date()
        let summary = "Activity log (\(activityBuffer.count) switches):\n" + activityBuffer.joined(separator: "\n")
        activityBuffer.removeAll()

        let params: [String: Any] = [
            "sessionKey": activitySessionKey,
            "message": summary,
            "idempotencyKey": UUID().uuidString
        ]
        sendRequest(id: "activity", method: "chat.send", params: params)
    }

    private func sendRequest(id: String, method: String, params: [String: Any]) {
        let request: [String: Any] = [
            "type": "req",
            "id": id,
            "method": method,
            "params": params
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8) else {
            print("Failed to serialize request")
            return
        }

        print("Sending \(method): \(text.prefix(200))...")

        webSocket?.send(.string(text)) { error in
            if let error = error {
                print("Send error: \(error)")
            } else {
                print("Sent \(method) successfully")
            }
        }
    }

    private func finishWithResponse() {
        guard let completion = self.completion else { return }

        let response = responseBuffer.isEmpty ? "" : responseBuffer
        guard !response.isEmpty else { return }  // Don't deliver empty responses

        responseBuffer = ""
        print(">>> Delivering response: \(response.prefix(50))...")
        completion(response)  // Already on main thread
    }

    private func showActivityNudge(_ message: String) {
        print(">>> Activity nudge: \(message)")
        DispatchQueue.main.async {
            let state = PizzaState.shared

            // Force UTF8 encoding
            let utf8Data = message.data(using: .utf8) ?? Data()
            let utf8String = String(data: utf8Data, encoding: .utf8) ?? message

            // Check pizza position for bubble side
            var bubbleOnLeft = false
            if let appDelegate = NSApp.delegate as? AppDelegate,
               let screen = NSScreen.main {
                let panelX = appDelegate.panel.frame.midX
                bubbleOnLeft = panelX > screen.frame.midX
            }

            state.chatDisplay = ChatDisplayState(
                isThinking: false,
                showResponse: true,
                botResponse: utf8String,
                bubbleOnLeft: bubbleOnLeft
            )
            state.mood = .surprised  // Get attention!

            // Hide after 8 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                state.chatDisplay = ChatDisplayState()
                state.mood = .happy
            }
        }
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        isConnected = false
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    let pizzaState = PizzaState.shared
    var chatPopover: NSPopover?
    var historyPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        setupPanel()
        setupMenuBar()
        setupMainMenu()

        // Watch for chat dialog trigger
        NotificationCenter.default.addObserver(forName: .showChatDialog, object: nil, queue: .main) { [weak self] _ in
            self?.showChat()
        }

        // Watch for history dialog trigger
        NotificationCenter.default.addObserver(forName: .showHistoryDialog, object: nil, queue: .main) { [weak self] _ in
            self?.showHistory()
        }
    }

    func setupMainMenu() {
        // Create main menu with Edit menu for copy/paste support
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit HomeSlice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (required for paste to work)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func setupPanel() {
        // Create floating panel (huge to test transparent click-through)
        let panelSize = NSSize(width: 600, height: 300)
        panel = NSPanel(
            contentRect: NSRect(
                x: NSScreen.main!.frame.midX - panelSize.width / 2,
                y: NSScreen.main!.frame.midY - panelSize.height / 2,
                width: panelSize.width,
                height: panelSize.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // Disable window shadow - we draw our own
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true  // Become key when text field needs input

        // Add SwiftUI content
        let hostingView = NSHostingView(rootView: KawaiiPizzaView().environmentObject(pizzaState))
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]

        // Disable clipping so content can extend beyond window bounds
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.masksToBounds = false

        panel.contentView = hostingView

        panel.orderFrontRegardless()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "🍕"
        }

        let menu = NSMenu()

        // Mood submenu
        let moodMenuItem = NSMenuItem(title: "Mood", action: nil, keyEquivalent: "")
        let moodSubmenu = NSMenu()

        for mood in PizzaMood.allCases {
            let item = NSMenuItem(title: mood.rawValue, action: #selector(changeMood(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mood
            moodSubmenu.addItem(item)
        }

        moodMenuItem.submenu = moodSubmenu
        menu.addItem(moodMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle visibility
        let toggleItem = NSMenuItem(title: "Hide Pizza", action: #selector(toggleVisibility), keyEquivalent: "h")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Reset position (debug)
        let resetItem = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        // Test response (debug)
        let testItem = NSMenuItem(title: "Test Response", action: #selector(testResponse), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        // Fun actions submenu
        let actionsMenuItem = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        let actionsSubmenu = NSMenu()

        let spinItem = NSMenuItem(title: "Do a Spin!", action: #selector(doSpin), keyEquivalent: "s")
        spinItem.target = self
        actionsSubmenu.addItem(spinItem)

        let jumpItem = NSMenuItem(title: "Jump!", action: #selector(doJump), keyEquivalent: "j")
        jumpItem.target = self
        actionsSubmenu.addItem(jumpItem)

        let danceItem = NSMenuItem(title: "Dance!", action: #selector(doDance), keyEquivalent: "d")
        danceItem.target = self
        actionsSubmenu.addItem(danceItem)

        actionsSubmenu.addItem(NSMenuItem.separator())

        let heartsItem = NSMenuItem(title: "Burst Hearts", action: #selector(burstHearts), keyEquivalent: "")
        heartsItem.target = self
        actionsSubmenu.addItem(heartsItem)

        let sparklesItem = NSMenuItem(title: "Burst Sparkles", action: #selector(burstSparkles), keyEquivalent: "")
        sparklesItem.target = self
        actionsSubmenu.addItem(sparklesItem)

        let starsItem = NSMenuItem(title: "Burst Stars", action: #selector(burstStars), keyEquivalent: "")
        starsItem.target = self
        actionsSubmenu.addItem(starsItem)

        actionsMenuItem.submenu = actionsSubmenu
        menu.addItem(actionsMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Chat
        let chatItem = NSMenuItem(title: "Chat with Bot", action: #selector(showChat), keyEquivalent: "c")
        chatItem.target = self
        menu.addItem(chatItem)

        let historyItem = NSMenuItem(title: "View History", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let configItem = NSMenuItem(title: "Configure Bot URL...", action: #selector(configureBotURL), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit HomeSlice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func showHistory() {
        if historyPopover == nil {
            historyPopover = NSPopover()
            historyPopover?.contentSize = NSSize(width: 300, height: 400)
            historyPopover?.behavior = .transient
            historyPopover?.animates = true
            historyPopover?.contentViewController = HistoryPopoverController(pizzaState: pizzaState)
        }

        if let popover = historyPopover {
            if popover.isShown {
                popover.close()
            } else {
                let panelBounds = panel.contentView!.bounds
                let rect = NSRect(x: panelBounds.midX - 10, y: panelBounds.midY, width: 20, height: 20)
                popover.show(relativeTo: rect, of: panel.contentView!, preferredEdge: .maxY)
            }
        }
    }

    @objc func showChat() {
        if chatPopover == nil {
            chatPopover = NSPopover()
            chatPopover?.contentSize = NSSize(width: 320, height: 450)
            chatPopover?.behavior = .transient
            chatPopover?.animates = true
            chatPopover?.contentViewController = ChatPopoverController(pizzaState: pizzaState)
        }

        if let popover = chatPopover {
            if popover.isShown {
                popover.close()
            } else {
                // Show relative to the panel center
                let panelBounds = panel.contentView!.bounds
                let rect = NSRect(x: panelBounds.midX - 10, y: panelBounds.midY, width: 20, height: 20)
                popover.show(relativeTo: rect, of: panel.contentView!, preferredEdge: .maxY)
            }
        }
    }

    @objc func configureBotURL() {
        let alert = NSAlert()
        alert.messageText = "Configure OpenClaw"
        alert.informativeText = "Enter your OpenClaw URL and webhook token:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))

        let urlLabel = NSTextField(labelWithString: "URL:")
        urlLabel.frame = NSRect(x: 0, y: 35, width: 40, height: 20)
        container.addSubview(urlLabel)

        let urlInput = NSTextField(frame: NSRect(x: 45, y: 33, width: 255, height: 24))
        urlInput.stringValue = pizzaState.botURL
        urlInput.placeholderString = "https://your-machine.ts.net"
        container.addSubview(urlInput)

        let tokenLabel = NSTextField(labelWithString: "Token:")
        tokenLabel.frame = NSRect(x: 0, y: 5, width: 40, height: 20)
        container.addSubview(tokenLabel)

        let tokenInput = NSSecureTextField(frame: NSRect(x: 45, y: 3, width: 255, height: 24))
        tokenInput.stringValue = pizzaState.botToken
        tokenInput.placeholderString = "your-webhook-token"
        container.addSubview(tokenInput)

        alert.accessoryView = container

        if alert.runModal() == .alertFirstButtonReturn {
            pizzaState.botURL = urlInput.stringValue
            pizzaState.botToken = tokenInput.stringValue
        }
    }

    @objc func changeMood(_ sender: NSMenuItem) {
        if let mood = sender.representedObject as? PizzaMood {
            pizzaState.mood = mood
        }
    }

    @objc func testResponse() {
        print(">>> testResponse called")
        // Single atomic update
        pizzaState.chatDisplay = ChatDisplayState(
            isThinking: false,
            showResponse: true,
            botResponse: "Test message from menu!"
        )
        pizzaState.mood = .happy
        print(">>> testResponse set atomically")
    }

    @objc func resetPosition() {
        print(">>> resetPosition called")
        print(">>> panel exists: \(panel != nil)")
        print(">>> panel.isVisible: \(panel.isVisible)")
        print(">>> panel.alphaValue: \(panel.alphaValue)")
        print(">>> panel.frame: \(panel.frame)")
        print(">>> panel.contentView: \(String(describing: panel.contentView))")
        print(">>> panel.contentView.frame: \(panel.contentView?.frame ?? .zero)")

        if let screen = NSScreen.main {
            let x = screen.frame.midX - 300
            let y = screen.frame.midY - 300

            // Force recreate the window content
            panel.alphaValue = 1.0
            panel.setFrame(NSRect(x: x, y: y, width: 600, height: 300), display: true)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)

            print(">>> After reset - frame: \(panel.frame), visible: \(panel.isVisible)")
        }
    }

    @objc func toggleVisibility() {
        pizzaState.isVisible.toggle()
        if pizzaState.isVisible {
            // Reset panel to center of screen
            if let screen = NSScreen.main {
                let x = screen.frame.midX - panel.frame.width / 2
                let y = screen.frame.midY - panel.frame.height / 2
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                print(">>> Panel moved to: \(panel.frame)")
            }
            panel.orderFrontRegardless()
            print(">>> Panel visible: \(panel.isVisible), frame: \(panel.frame)")
        } else {
            panel.orderOut(nil)
        }
        if let item = statusItem.menu?.items.first(where: { $0.title == "Hide Pizza" || $0.title == "Show Pizza" }) {
            item.title = pizzaState.isVisible ? "Hide Pizza" : "Show Pizza"
        }
    }

    @objc func doSpin() {
        NotificationCenter.default.post(name: .doSpin, object: nil)
    }

    @objc func doJump() {
        NotificationCenter.default.post(name: .doJump, object: nil)
    }

    @objc func doDance() {
        NotificationCenter.default.post(name: .doDance, object: nil)
    }

    @objc func burstHearts() {
        pizzaState.particleType = .hearts
        pizzaState.showParticles = true
    }

    @objc func burstSparkles() {
        pizzaState.particleType = .sparkles
        pizzaState.showParticles = true
    }

    @objc func burstStars() {
        pizzaState.particleType = .stars
        pizzaState.showParticles = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - History Popover Controller

class HistoryPopoverController: NSViewController {
    let pizzaState: PizzaState

    init(pizzaState: PizzaState) {
        self.pizzaState = pizzaState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let historyView = ChatHistoryView().environmentObject(pizzaState)
        let hostingView = NSHostingView(rootView: historyView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        self.view = hostingView
    }
}

struct ChatHistoryView: View {
    @EnvironmentObject var pizzaState: PizzaState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Chat History")
                    .font(.headline)
                Spacer()
                Text("\(pizzaState.chatHistory.count) messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Messages
            if pizzaState.chatHistory.isEmpty {
                Spacer()
                Text("No messages yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(pizzaState.chatHistory) { message in
                                ChatHistoryBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onAppear {
                        // Scroll to bottom
                        if let last = pizzaState.chatHistory.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 400)
    }
}

struct ChatHistoryBubble: View {
    let message: ChatMessage

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer() }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(isUser ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(12)

                Text(timeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !isUser { Spacer() }
        }
    }

    var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - Chat Popover Controller (History + Input)

class ChatPopoverController: NSViewController {
    let pizzaState: PizzaState

    init(pizzaState: PizzaState) {
        self.pizzaState = pizzaState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let chatView = FullChatView().environmentObject(pizzaState)
        let hostingView = NSHostingView(rootView: chatView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 450)
        self.view = hostingView
    }
}

struct FullChatView: View {
    @EnvironmentObject var pizzaState: PizzaState
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🍕 HomeSlice")
                    .font(.headline)
                Spacer()
                if !pizzaState.chatHistory.isEmpty {
                    Text("\(pizzaState.chatHistory.count) messages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Messages
            if pizzaState.chatHistory.isEmpty {
                Spacer()
                Text("Say hi! 👋")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(pizzaState.chatHistory) { message in
                                ChatHistoryBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: pizzaState.chatHistory.count) { _ in
                        if let last = pizzaState.chatHistory.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let last = pizzaState.chatHistory.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 8) {
                TextField("Ask me anything...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(inputText.isEmpty ? .gray : .blue)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty)
            }
            .padding()
        }
        .frame(width: 320, height: 450)
        .onAppear {
            isInputFocused = true
        }
    }

    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        pizzaState.chatMessage = inputText
        inputText = ""
        pizzaState.sendMessage()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let doSpin = Notification.Name("doSpin")
    static let doJump = Notification.Name("doJump")
    static let doDance = Notification.Name("doDance")
    static let showChatDialog = Notification.Name("showChatDialog")
    static let showHistoryDialog = Notification.Name("showHistoryDialog")
}

// MARK: - Kawaii Pizza View

struct KawaiiPizzaView: View {
    @EnvironmentObject var pizzaState: PizzaState
    @State private var bobOffset: CGFloat = 0
    @State private var isBlinking = false
    @State private var breatheScale: CGFloat = 1.0
    @State private var wiggleAngle: Double = 0
    @State private var spinAngle: Double = 0
    @State private var jumpOffset: CGFloat = 0
    @State private var danceOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Shadow as bottom layer in ZStack (not using .background)
            PizzaShadow()
                .scaleEffect(breatheScale)
                .rotationEffect(.degrees(wiggleAngle + spinAngle))
                .offset(x: danceOffset, y: bobOffset + jumpOffset + 10)

            // Particle effects layer
            if pizzaState.showParticles {
                ParticleView(type: pizzaState.particleType)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            pizzaState.showParticles = false
                        }
                    }
            }

            ZStack {
                // Pizza body
                ZStack {
                    PizzaSlice()
                        .scaleEffect(breatheScale)

                    KawaiiFace(isBlinking: isBlinking, mood: pizzaState.mood)
                        .offset(y: 15)
                        .scaleEffect(breatheScale)
                }
                .rotationEffect(.degrees(wiggleAngle + spinAngle))

                // Speech bubble for mood
                if pizzaState.mood != .happy && !pizzaState.showChatInput && !pizzaState.chatDisplay.showResponse && !pizzaState.chatDisplay.isThinking {
                    SpeechBubble(mood: pizzaState.mood)
                        .offset(x: 50, y: -50)
                        .transition(.scale.combined(with: .opacity))
                }

                // Thinking indicator
                if pizzaState.chatDisplay.isThinking {
                    ThinkingBubble()
                        .offset(x: 60, y: -60)
                }

                // Bot response bubble - position based on pizza screen location
                if pizzaState.chatDisplay.showResponse {
                    ResponseBubble(message: pizzaState.chatDisplay.botResponse)
                        .offset(
                            x: pizzaState.chatDisplay.bubbleOnLeft ? -160 : 160,
                            y: -60
                        )
                }

                // Chat input
                if pizzaState.showChatInput {
                    ChatInputBubble()
                        .environmentObject(pizzaState)
                        .offset(x: 80, y: -80)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .offset(x: danceOffset, y: bobOffset + jumpOffset)
            .onTapGesture {
                if pizzaState.botURL.isEmpty {
                    handleTap()
                } else {
                    // Open chat window (includes history + input)
                    NotificationCenter.default.post(name: .showChatDialog, object: nil)
                }
            }
            .contextMenu {
                Button("Chat") { pizzaState.showChatInput = true }
                Divider()
                Button("Happy") { pizzaState.mood = .happy }
                Button("Excited") { pizzaState.mood = .excited }
                Button("Sleepy") { pizzaState.mood = .sleepy }
                Button("Love") { pizzaState.mood = .love }
                Button("Surprised") { pizzaState.mood = .surprised }
                Divider()
                Button("Spin!") { performSpin() }
                Button("Jump!") { performJump() }
                Button("Dance!") { performDance() }
                Divider()
                Button("Burst Hearts") {
                    pizzaState.particleType = .hearts
                    pizzaState.showParticles = true
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Temporarily remove animation to debug
        // .animation(.spring(response: 0.3), value: pizzaState.mood)
        .onAppear {
            startAnimations()
            setupNotifications()
        }
    }

    private func handleTap() {
        // Random reaction on tap
        let reactions = ["spin", "jump", "wiggle", "hearts"]
        let reaction = reactions.randomElement()!

        switch reaction {
        case "spin":
            performSpin()
        case "jump":
            performJump()
        case "wiggle":
            performExtraWiggle()
        case "hearts":
            pizzaState.particleType = .hearts
            pizzaState.showParticles = true
        default:
            break
        }
    }

    private func performExtraWiggle() {
        withAnimation(.easeInOut(duration: 0.08)) {
            wiggleAngle = 8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.08)) {
                wiggleAngle = -8
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.easeInOut(duration: 0.08)) {
                wiggleAngle = 5
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.easeInOut(duration: 0.08)) {
                wiggleAngle = -5
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.easeInOut(duration: 0.08)) {
                wiggleAngle = 0
            }
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(forName: .doSpin, object: nil, queue: .main) { _ in
            performSpin()
        }
        NotificationCenter.default.addObserver(forName: .doJump, object: nil, queue: .main) { _ in
            performJump()
        }
        NotificationCenter.default.addObserver(forName: .doDance, object: nil, queue: .main) { _ in
            performDance()
        }
    }

    private func performSpin() {
        withAnimation(.easeInOut(duration: 0.5)) {
            spinAngle += 360
        }
    }

    private func performJump() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
            jumpOffset = -40
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                jumpOffset = 0
            }
        }
    }

    private func performDance() {
        // Fun little side-to-side dance
        let moves: [(offset: CGFloat, delay: Double)] = [
            (-15, 0), (15, 0.1), (-15, 0.2), (15, 0.3),
            (-10, 0.4), (10, 0.5), (-5, 0.6), (0, 0.7)
        ]

        for move in moves {
            DispatchQueue.main.asyncAfter(deadline: .now() + move.delay) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    danceOffset = move.offset
                }
            }
        }
    }

    private func startAnimations() {
        // Floating bob animation
        withAnimation(
            .easeInOut(duration: 1.5)
            .repeatForever(autoreverses: true)
        ) {
            bobOffset = -8
        }

        // Breathing animation
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: true)
        ) {
            breatheScale = 1.02
        }

        // Blink timer
        Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { _ in
            blink()
        }

        // Wiggle timer
        Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            wiggle()
        }

        // Random action timer (occasional surprise animations)
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
            randomAction()
        }
    }

    private func randomAction() {
        let actions = ["wiggle", "none", "none", "none"] // Mostly nothing, occasionally wiggle
        if actions.randomElement() == "wiggle" {
            performExtraWiggle()
        }
    }

    private func blink() {
        guard pizzaState.mood != .sleepy else { return }
        withAnimation(.easeInOut(duration: 0.1)) {
            isBlinking = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.1)) {
                isBlinking = false
            }
        }
    }

    private func wiggle() {
        withAnimation(.easeInOut(duration: 0.1)) {
            wiggleAngle = 3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.1)) {
                wiggleAngle = -3
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut(duration: 0.1)) {
                wiggleAngle = 0
            }
        }
    }
}

// MARK: - Particle View

struct ParticleView: View {
    let type: ParticleType
    @State private var particles: [Particle] = []

    struct Particle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var scale: CGFloat
        var opacity: Double
        var rotation: Double
    }

    var particleEmoji: String {
        switch type {
        case .hearts: return "❤️"
        case .sparkles: return "✨"
        case .stars: return "⭐"
        }
    }

    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                Text(particleEmoji)
                    .font(.system(size: 20))
                    .scaleEffect(particle.scale)
                    .opacity(particle.opacity)
                    .rotationEffect(.degrees(particle.rotation))
                    .position(x: particle.x, y: particle.y)
            }
        }
        .onAppear {
            createParticles()
            animateParticles()
        }
    }

    private func createParticles() {
        particles = (0..<12).map { _ in
            Particle(
                x: 90 + CGFloat.random(in: -20...20),
                y: 100,
                scale: CGFloat.random(in: 0.5...1.0),
                opacity: 1.0,
                rotation: Double.random(in: -30...30)
            )
        }
    }

    private func animateParticles() {
        for i in particles.indices {
            let randomX = CGFloat.random(in: -60...60)
            let randomY = CGFloat.random(in: -80 ... -30)
            let delay = Double.random(in: 0...0.3)

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.8)) {
                    particles[i].x += randomX
                    particles[i].y += randomY
                    particles[i].opacity = 0
                    particles[i].rotation += Double.random(in: -180...180)
                }
            }
        }
    }
}

// MARK: - Speech Bubble

struct SpeechBubble: View {
    let mood: PizzaMood

    var message: String {
        switch mood {
        case .happy: return ""
        case .excited: return "Yay!"
        case .sleepy: return "zzZ..."
        case .love: return "♥‿♥"
        case .surprised: return "!!"
        }
    }

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white)
                    .shadow(radius: 2)
            )
            .offset(y: -5)
    }
}

// MARK: - Chat UI Components

// NSTextField wrapper for reliable keyboard input
struct MacTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.font = .systemFont(ofSize: 12)
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .none
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Auto-focus
        DispatchQueue.main.async {
            if let window = nsView.window, window.firstResponder != nsView {
                window.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacTextField

        init(_ parent: MacTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

struct ChatInputBubble: View {
    @EnvironmentObject var pizzaState: PizzaState

    var body: some View {
        HStack(spacing: 8) {
            MacTextField(
                text: $pizzaState.chatMessage,
                placeholder: "Ask me...",
                onSubmit: { pizzaState.sendMessage() }
            )
            .frame(width: 140, height: 22)

            Button(action: { pizzaState.sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)

            Button(action: { pizzaState.showChatInput = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white)
                .shadow(radius: 3)
        )
    }
}

struct ThinkingBubble: View {
    @State private var dotCount = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.gray)
                    .frame(width: 8, height: 8)
                    .opacity(dotCount > i ? 1 : 0.3)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 3)
        )
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                dotCount = (dotCount + 1) % 4
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct ResponseBubble: View {
    let message: String
    var onLeft: Bool = false  // Show bubble on left side of pizza

    var body: some View {
        ScrollView {
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.black)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 280)
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 4)
        )
    }
}

// MARK: - Pizza Shadow

struct PizzaShadow: View {
    var body: some View {
        Ellipse()
            .fill(Color.black.opacity(0.18))
            .blur(radius: 10)
            .frame(width: 85, height: 30)
            .offset(y: 58)
    }
}

// MARK: - Pizza Slice Shape

struct PizzaSlice: View {
    var body: some View {
        ZStack {
            // Cheese (main triangle)
            PizzaTriangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.85, blue: 0.4),
                            Color(red: 1.0, green: 0.75, blue: 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Crust
            CrustShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.85, green: 0.65, blue: 0.35),
                            Color(red: 0.7, green: 0.5, blue: 0.25)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Pepperoni
            Pepperoni()
                .offset(x: -20, y: 35)

            Pepperoni()
                .offset(x: 18, y: 50)

            Pepperoni()
                .scaleEffect(0.8)
                .offset(x: 5, y: 15)
        }
        .frame(width: 120, height: 140)
    }
}

struct PizzaTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tipY: CGFloat = 10
        let baseY: CGFloat = rect.height - 25
        let leftX: CGFloat = 15
        let rightX: CGFloat = rect.width - 15
        let tipX: CGFloat = rect.midX

        path.move(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: CGPoint(x: leftX, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: baseY),
            control: CGPoint(x: rect.midX, y: baseY + 10)
        )
        path.addLine(to: CGPoint(x: tipX, y: tipY))
        path.closeSubpath()

        return path
    }
}

struct CrustShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let baseY: CGFloat = rect.height - 25
        let bottomY: CGFloat = rect.height - 5
        let leftX: CGFloat = 10
        let rightX: CGFloat = rect.width - 10

        path.move(to: CGPoint(x: leftX + 5, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: rightX - 5, y: baseY),
            control: CGPoint(x: rect.midX, y: baseY + 10)
        )
        path.addQuadCurve(
            to: CGPoint(x: leftX + 5, y: baseY),
            control: CGPoint(x: rect.midX, y: bottomY + 5)
        )
        path.closeSubpath()

        return path
    }
}

struct Pepperoni: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.8, green: 0.2, blue: 0.15))
                .frame(width: 22, height: 22)

            // Darker spots on pepperoni
            Circle()
                .fill(Color(red: 0.6, green: 0.15, blue: 0.1))
                .frame(width: 5, height: 5)
                .offset(x: -4, y: -3)

            Circle()
                .fill(Color(red: 0.6, green: 0.15, blue: 0.1))
                .frame(width: 4, height: 4)
                .offset(x: 4, y: 4)
        }
    }
}

// MARK: - Kawaii Face

struct KawaiiFace: View {
    let isBlinking: Bool
    let mood: PizzaMood

    var body: some View {
        VStack(spacing: 8) {
            // Eyes
            HStack(spacing: 20) {
                KawaiiEye(isBlinking: isBlinking, mood: mood)
                KawaiiEye(isBlinking: isBlinking, mood: mood, isRight: true)
            }

            // Cheeks and smile
            ZStack {
                HStack(spacing: 35) {
                    // Rosy cheeks
                    Circle()
                        .fill(cheekColor)
                        .frame(width: 12, height: 12)

                    Circle()
                        .fill(cheekColor)
                        .frame(width: 12, height: 12)
                }

                // Mouth based on mood
                MouthView(mood: mood)
            }
        }
    }

    var cheekColor: Color {
        switch mood {
        case .love: return Color.red.opacity(0.6)
        case .excited: return Color.pink.opacity(0.7)
        default: return Color.pink.opacity(0.5)
        }
    }
}

struct MouthView: View {
    let mood: PizzaMood

    var body: some View {
        Group {
            switch mood {
            case .happy:
                SmilePath()
                    .stroke(Color(red: 0.4, green: 0.25, blue: 0.15), lineWidth: 2)
                    .frame(width: 15, height: 8)

            case .excited:
                // Big open smile
                Ellipse()
                    .fill(Color(red: 0.4, green: 0.25, blue: 0.15))
                    .frame(width: 16, height: 10)

            case .sleepy:
                // Wavy sleepy mouth
                SleepyMouth()
                    .stroke(Color(red: 0.4, green: 0.25, blue: 0.15), lineWidth: 2)
                    .frame(width: 12, height: 6)

            case .love:
                // Cat-like happy mouth
                CatSmile()
                    .stroke(Color(red: 0.4, green: 0.25, blue: 0.15), lineWidth: 2)
                    .frame(width: 20, height: 10)

            case .surprised:
                // O mouth
                Circle()
                    .fill(Color(red: 0.4, green: 0.25, blue: 0.15))
                    .frame(width: 10, height: 10)
            }
        }
        .offset(y: 2)
    }
}

struct SleepyMouth: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.height)
        )
        return path
    }
}

struct CatSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Left curve
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.height * 0.7),
            control: CGPoint(x: rect.width * 0.25, y: rect.height)
        )
        // Right curve
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: 0),
            control: CGPoint(x: rect.width * 0.75, y: rect.height)
        )
        return path
    }
}

struct KawaiiEye: View {
    let isBlinking: Bool
    let mood: PizzaMood
    var isRight: Bool = false

    var body: some View {
        ZStack {
            switch mood {
            case .sleepy:
                // Closed sleepy eyes (curved lines)
                SleepyEye()
                    .stroke(Color.black, lineWidth: 2)
                    .frame(width: 16, height: 8)

            case .love:
                // Heart eyes
                HeartShape()
                    .fill(Color.red)
                    .frame(width: 18, height: 16)

            case .surprised:
                // Big round eyes
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(.black)
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
                    .offset(x: -3, y: -3)

            case .excited:
                // Sparkly excited eyes
                ZStack {
                    Ellipse()
                        .fill(.white)
                        .frame(width: 20, height: isBlinking ? 2 : 26)
                    if !isBlinking {
                        Ellipse()
                            .fill(.black)
                            .frame(width: 12, height: 16)
                            .offset(y: 2)
                        // Extra sparkles
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(.white)
                                .frame(width: CGFloat(6 - i * 2), height: CGFloat(6 - i * 2))
                                .offset(
                                    x: CGFloat([-3, 4, -1][i]),
                                    y: CGFloat([-4, 2, 6][i])
                                )
                        }
                    }
                }

            default:
                // Normal happy eyes
                ZStack {
                    Ellipse()
                        .fill(.white)
                        .frame(width: 20, height: isBlinking ? 2 : 24)

                    if !isBlinking {
                        Ellipse()
                            .fill(.black)
                            .frame(width: 12, height: 14)
                            .offset(y: 2)

                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .offset(x: -3, y: -2)

                        Circle()
                            .fill(.white)
                            .frame(width: 3, height: 3)
                            .offset(x: 3, y: 4)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.1), value: isBlinking)
    }
}

struct SleepyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.height)
        )
        return path
    }
}

struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        path.move(to: CGPoint(x: width / 2, y: height))
        path.addCurve(
            to: CGPoint(x: 0, y: height / 4),
            control1: CGPoint(x: width / 2, y: height * 3 / 4),
            control2: CGPoint(x: 0, y: height / 2)
        )
        path.addArc(
            center: CGPoint(x: width / 4, y: height / 4),
            radius: width / 4,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addArc(
            center: CGPoint(x: width * 3 / 4, y: height / 4),
            radius: width / 4,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: width / 2, y: height),
            control1: CGPoint(x: width, y: height / 2),
            control2: CGPoint(x: width / 2, y: height * 3 / 4)
        )

        return path
    }
}

struct SmilePath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: 0),
            control: CGPoint(x: rect.midX, y: rect.height)
        )
        return path
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
