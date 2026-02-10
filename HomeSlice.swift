import AppKit
import SwiftUI
import Combine
import CryptoKit
import Security
import Carbon.HIToolbox

// MARK: - Pizza State

enum PizzaMood: String, CaseIterable {
    case happy = "Happy"
    case excited = "Excited"
    case sleepy = "Sleepy"
    case love = "Love"
    case surprised = "Surprised"
}

enum CompanionType: String, CaseIterable {
    case pizza = "Pizza"
    case cat = "Cat"
    case jacob = "Jacob"
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
    @Published var companionType: CompanionType = .pizza

    // Chat state - single published property for atomic updates
    @Published var showChatInput: Bool = false
    @Published var chatMessage: String = ""
    @Published var chatDisplay: ChatDisplayState = ChatDisplayState()

    // Message queue - messages wait until user dismisses current one
    @Published var pendingMessages: [String] = []
    @Published var pendingMessageCount: Int = 0  // Shows badge on bubble

    // Chat UI preferences
    var showExpandedChat: Bool {
        get { UserDefaults.standard.bool(forKey: "showExpandedChat") }
        set { UserDefaults.standard.set(newValue, forKey: "showExpandedChat") }
    }

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

    private var pollTimer: Timer?
    private var lastMessageTimestamp: Int64 = 0
    private var seenMessageHashes: Set<String> = []

    init() {
        self.botURL = UserDefaults.standard.string(forKey: "botURL") ?? ""
        self.botToken = UserDefaults.standard.string(forKey: "botToken") ?? ""
        setupAppMonitoring()

        // Connect to gateway and fetch history after identity is initialized
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            guard DeviceIdentity.shared.isInitialized else {
                print("[Startup] Waiting for device identity...")
                return
            }
            guard !self.botURL.isEmpty, !self.botToken.isEmpty else {
                print("[Startup] No bot URL/token configured")
                return
            }
            // Connect to gateway for pizza chat
            GatewayClient.shared.connectForAlerts(url: self.botURL, token: self.botToken)
            // Fetch initial history
            self.fetchHistory()
            // Polling disabled - using WebSocket events instead
            // self.startPolling()
        }
    }

    /*
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pollForNewAlerts()
        }
        print("[Polling] Started polling for alerts every 10s")
    }
    */

    /*
    private func pollForNewAlerts() {
        guard !botURL.isEmpty, !botToken.isEmpty else { return }

        var httpURL = botURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        if httpURL.hasSuffix("/gateway") {
            httpURL = String(httpURL.dropLast("/gateway".count))
        }
        httpURL += "/tools/invoke"

        guard let url = URL(string: httpURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Poll main session for alerts (messages starting with ✔️)
        let body: [String: Any] = [
            "tool": "sessions_history",
            "args": [
                "sessionKey": "agent:main:main",
                "limit": 20,
                "includeTools": false
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let content = result["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let textString = firstBlock["text"] as? String,
                  let textData = textString.data(using: .utf8),
                  let innerJson = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
                  let messages = innerJson["messages"] as? [[String: Any]] else { return }

            // Check for new messages using timestamp + content hash for deduplication
            var newMessages: [(timestamp: Int64, text: String, hash: String)] = []

            for msg in messages {
                let timestamp = msg["timestamp"] as? Int64 ?? 0
                let role = msg["role"] as? String ?? ""
                guard role == "assistant" else { continue }

                var text = ""
                if let contentBlocks = msg["content"] as? [[String: Any]] {
                    for block in contentBlocks {
                        if let type = block["type"] as? String, type == "text",
                           let blockText = block["text"] as? String {
                            text += blockText
                        }
                    }
                }

                guard !text.isEmpty else { continue }

                // Only show messages starting with ✔️ (alerts)
                guard text.hasPrefix("✔️") else { continue }

                // Create hash from timestamp + text for deduplication
                let hash = "\(timestamp):\(text.hashValue)"

                // Skip if already seen
                if self.seenMessageHashes.contains(hash) { continue }

                // Skip if older than last known timestamp
                if timestamp <= self.lastMessageTimestamp { continue }

                newMessages.append((timestamp: timestamp, text: text, hash: hash))
            }

            // Sort by timestamp and process
            for msg in newMessages.sorted(by: { $0.timestamp < $1.timestamp }) {
                DispatchQueue.main.async {
                    // Double-check we haven't seen this
                    guard !self.seenMessageHashes.contains(msg.hash) else { return }
                    self.seenMessageHashes.insert(msg.hash)
                    self.lastMessageTimestamp = max(self.lastMessageTimestamp, msg.timestamp)

                    print("[Polling] New alert: \(msg.text.prefix(50))...")

                    // Add to history
                    self.addToHistory(role: "assistant", content: msg.text)

                    // Show notification
                    var bubbleOnLeft = false
                    if let appDelegate = NSApp.delegate as? AppDelegate,
                       let screen = NSScreen.main {
                        let panelX = appDelegate.panel.frame.midX
                        bubbleOnLeft = panelX > screen.frame.midX
                    }
                    self.showOrQueueMessage(msg.text, bubbleOnLeft: bubbleOnLeft)
                    self.mood = .surprised
                }
            }
        }.resume()
    }
    */

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

            // Update current and add to history
            self.currentApp = appName
            self.recentApps.append((app: appName, timestamp: Date()))

            // Keep only recent entries
            if self.recentApps.count > self.maxRecentApps {
                self.recentApps.removeFirst()
            }

            print(">>> App changed to: \(appName)")
        }
    }

    func addToHistory(role: String, content: String) {
        // Skip if this is a duplicate of the last message
        if let last = chatHistory.last,
           last.role == role,
           last.content == content {
            print(">>> Skipping duplicate message")
            return
        }

        let message = ChatMessage(role: role, content: content, timestamp: Date())
        chatHistory.append(message)
        if chatHistory.count > maxHistoryMessages {
            chatHistory.removeFirst()
        }
    }

    func fetchHistory() {
        guard !botURL.isEmpty, !botToken.isEmpty else { return }

        // Convert WS URL to HTTP URL
        var httpURL = botURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        // Remove /gateway path if present and add /tools/invoke
        if httpURL.hasSuffix("/gateway") {
            httpURL = String(httpURL.dropLast("/gateway".count))
        }
        httpURL += "/tools/invoke"

        guard let url = URL(string: httpURL) else {
            print("[History] Invalid URL: \(httpURL)")
            return
        }

        print("[History] Fetching from: \(httpURL)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Fetch from main session for alerts (messages starting with ✔️)
        let body: [String: Any] = [
            "tool": "sessions_history",
            "args": [
                "sessionKey": "agent:main:main",
                "limit": 200,
                "includeTools": false
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil else {
                print("[History] Error: \(error?.localizedDescription ?? "unknown")")
                return
            }

            // Parse response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[History] Failed to parse JSON")
                return
            }

            // Extract messages - API returns result.content[0].text as JSON string
            var messages: [[String: Any]] = []
            if let msgs = json["messages"] as? [[String: Any]] {
                messages = msgs
            } else if let result = json["result"] as? [String: Any],
                      let content = result["content"] as? [[String: Any]],
                      let firstBlock = content.first,
                      let textString = firstBlock["text"] as? String,
                      let textData = textString.data(using: .utf8),
                      let innerJson = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
                      let msgs = innerJson["messages"] as? [[String: Any]] {
                messages = msgs
            }

            guard !messages.isEmpty else {
                // Print raw response for debugging
                let raw = String(data: data, encoding: .utf8) ?? "nil"
                print("[History] No messages found. Response: \(raw.prefix(500))")
                return
            }

            print("[History] Found \(messages.count) messages")

            DispatchQueue.main.async {
                guard let self = self else { return }

                var loadedMessages: [ChatMessage] = []

                for msg in messages {
                    let role = msg["role"] as? String ?? "unknown"
                    guard role == "user" || role == "assistant" else { continue }

                    // Extract text content
                    var text = ""
                    if let content = msg["content"] as? [[String: Any]] {
                        for block in content {
                            if let type = block["type"] as? String, type == "text",
                               let blockText = block["text"] as? String {
                                text += blockText
                            }
                        }
                    } else if let content = msg["content"] as? String {
                        text = content
                    }

                    guard !text.isEmpty else { continue }

                    // Only show messages starting with ✔️ (alerts)
                    guard text.hasPrefix("✔️") else { continue }

                    // Parse timestamp if available (could be createdAt string or timestamp int)
                    var timestamp = Date()
                    if let createdAt = msg["createdAt"] as? String {
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        timestamp = formatter.date(from: createdAt) ?? Date()
                    } else if let ts = msg["timestamp"] as? Int64 {
                        timestamp = Date(timeIntervalSince1970: Double(ts) / 1000.0)
                    } else if let ts = msg["timestamp"] as? Int {
                        timestamp = Date(timeIntervalSince1970: Double(ts) / 1000.0)
                    }

                    loadedMessages.append(ChatMessage(role: role, content: text, timestamp: timestamp))
                }

                if !loadedMessages.isEmpty {
                    self.chatHistory = loadedMessages
                    // Track timestamps and hashes for polling deduplication
                    for msg in messages {
                        if let ts = msg["timestamp"] as? Int64 {
                            self.lastMessageTimestamp = max(self.lastMessageTimestamp, ts)
                            // Build hash from content
                            var text = ""
                            if let contentBlocks = msg["content"] as? [[String: Any]] {
                                for block in contentBlocks {
                                    if let type = block["type"] as? String, type == "text",
                                       let blockText = block["text"] as? String {
                                        text += blockText
                                    }
                                }
                            }
                            if !text.isEmpty {
                                self.seenMessageHashes.insert("\(ts):\(text.hashValue)")
                            }
                        }
                    }
                    print("[History] Loaded \(loadedMessages.count) messages, tracking \(self.seenMessageHashes.count) hashes")
                } else {
                    print("[History] No valid messages to display")
                }
            }
        }.resume()
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
        NotificationCenter.default.post(name: .hideChatDialog, object: nil)

        // Add user message to history
        addToHistory(role: "user", content: message)

        // Calculate bubble position based on pizza location
        var bubbleOnLeft = false
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let screen = NSScreen.main {
            let panelX = appDelegate.panel.frame.midX
            bubbleOnLeft = panelX > screen.frame.midX
        }

        // Single atomic update to start thinking
        chatDisplay = ChatDisplayState(isThinking: true, showResponse: false, botResponse: "", bubbleOnLeft: bubbleOnLeft)
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

                    // Show message or queue it if one is already showing
                    self.showOrQueueMessage(utf8String, bubbleOnLeft: bubbleOnLeft)
                    self.mood = .happy
                } else {
                    // Show error message
                    self.showOrQueueMessage("Couldn't reach bot!", bubbleOnLeft: false)
                    self.mood = .surprised
                }
            }
        }
    }

    // Show message immediately or add to queue
    func showOrQueueMessage(_ message: String, bubbleOnLeft: Bool) {
        if chatDisplay.showResponse {
            // Already showing a message, queue this one
            pendingMessages.append(message)
            pendingMessageCount = pendingMessages.count
            print(">>> Queued message, \(pendingMessages.count) pending")
        } else {
            // Show immediately
            chatDisplay = ChatDisplayState(
                isThinking: false,
                showResponse: true,
                botResponse: message,
                bubbleOnLeft: bubbleOnLeft
            )
        }
    }

    // User dismisses current message - show next if queued
    func dismissResponse() {
        if let nextMessage = pendingMessages.first {
            pendingMessages.removeFirst()
            pendingMessageCount = pendingMessages.count

            // Determine bubble position
            var bubbleOnLeft = false
            if let appDelegate = NSApp.delegate as? AppDelegate,
               let screen = NSScreen.main {
                let panelX = appDelegate.panel.frame.midX
                bubbleOnLeft = panelX > screen.frame.midX
            }

            chatDisplay = ChatDisplayState(
                isThinking: false,
                showResponse: true,
                botResponse: nextMessage,
                bubbleOnLeft: bubbleOnLeft
            )
            print(">>> Showing next queued message, \(pendingMessages.count) remaining")
        } else {
            // No more messages - reset display and mood
            chatDisplay = ChatDisplayState(isThinking: false, showResponse: false, botResponse: "")
            pendingMessageCount = 0
            mood = .happy
        }
    }

    // Dismiss all messages
    func dismissAllResponses() {
        pendingMessages.removeAll()
        pendingMessageCount = 0
        chatDisplay = ChatDisplayState(isThinking: false, showResponse: false, botResponse: "")
        mood = .happy
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
    private var _isInitialized = false

    /// Call this at app startup to trigger Keychain prompt before any network calls
    func initialize() {
        guard !_isInitialized else { return }
        _isInitialized = true
        _ = privateKey  // Triggers Keychain access
        print("Device identity initialized: \(deviceId.prefix(16))...")
    }

    var isInitialized: Bool { _isInitialized }

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

    private func saveToKeychain(tag: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
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

    // Reset identity (for debugging - generates fresh keypair)
    func resetIdentity() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: privateKeyTag
        ]
        SecItemDelete(query as CFDictionary)
        _privateKey = nil
        _isInitialized = false
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

    /// Connect to gateway for alerts (called at startup)
    func connectForAlerts(url: String, token: String) {
        guard !isConnected else {
            print("[Alerts] Already connected")
            return
        }
        self.gatewayURL = url
        self.gatewayToken = token
        print("[Alerts] Connecting to gateway for alerts...")
        connect()
    }

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
        let sessionKey = payload["sessionKey"] as? String ?? ""

        // Log all events with session info
        if !sessionKey.isEmpty {
            print("[Event] \(event) | session: \(sessionKey.prefix(50))")
        } else {
            print("[Event] \(event)")
        }

        switch event {
        case "connect.challenge":
            print("Got challenge, sending connect request...")
            challengeNonce = payload["nonce"] as? String
            challengeTs = payload["ts"] as? Int64
            sendConnectRequest()

        case "chat":
            // Handle main session for alerts (messages starting with ✔️)
            // Pizza sessions are handled in "agent" case to avoid duplicate responses
            let sessionKey = payload["sessionKey"] as? String ?? ""
            let isMainSession = sessionKey == "agent:main:main"

            guard isMainSession else {
                return
            }

            // Extract assistant message content
            if let message = payload["message"] as? [String: Any],
               let role = message["role"] as? String, role == "assistant",
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if let type = block["type"] as? String, type == "text",
                       let text = block["text"] as? String {
                        // Only capture messages starting with ✔️
                        if text.hasPrefix("✔️") {
                            responseBuffer = text
                            print("[Alerts] captured: \(text.prefix(50))...")
                        }
                    }
                }
            }
            // Check for completion (state: "final")
            if let state = payload["state"] as? String, state == "final" {
                if !responseBuffer.isEmpty {
                    print("[Alerts] delivering: \(responseBuffer.prefix(50))...")
                    showActivityNudge(responseBuffer)
                    responseBuffer = ""
                }
            }

        case "agent":
            // Process pizza sessions OR main session alerts (messages starting with ✔️)
            let sessionKey = payload["sessionKey"] as? String ?? ""
            let isPizzaSession = sessionKey.hasPrefix("agent:main:app:pizza:")
            let isMainSession = sessionKey == "agent:main:main"

            guard isPizzaSession || isMainSession else {
                return
            }

            // Capture streaming text from assistant
            if let stream = payload["stream"] as? String, stream == "assistant",
               let data = payload["data"] as? [String: Any],
               let text = data["text"] as? String {
                // For pizza sessions, capture all; for main session, only ✔️ alerts
                if isPizzaSession {
                    responseBuffer = text
                } else if isMainSession && text.hasPrefix("✔️") {
                    responseBuffer = text
                    print("[Alerts agent] captured: \(text.prefix(50))...")
                }
            }

            // Check for run completion
            if let data = payload["data"] as? [String: Any],
               let phase = data["phase"] as? String, phase == "end" {
                if isMainSession {
                    if !responseBuffer.isEmpty && responseBuffer.hasPrefix("✔️") {
                        print("[Alerts agent] delivering: \(responseBuffer.prefix(50))...")
                        showActivityNudge(responseBuffer)
                        responseBuffer = ""
                    }
                } else if isPizzaSession {
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
                // Subscribe to Telegram alerts session
                subscribeToAlerts()
                if let msg = pendingMessage {
                    pendingMessage = nil
                    sendChatMessage(msg)
                }
            } else {
                let error = payload["error"] as? String ?? "Connection failed"
                print("Connect failed: \(error)")
                completion?(nil)
            }
        } else if id == "3" {
            // sessions.subscribe response
            if ok {
                print("[Alerts] Subscribed to Telegram alerts session")
            } else {
                let error = payload["error"] as? String ?? "Subscribe failed"
                print("[Alerts] Subscribe failed: \(error)")
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
        let scopes = ["operator.read", "operator.write", "operator.admin"]
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

    private func subscribeToAlerts() {
        // Subscribe to Telegram alerts group session for live notifications
        let alertsSessionKey = "agent:main:telegram:group:-1003723640588"
        let params: [String: Any] = [
            "sessionKeys": [alertsSessionKey],
            "events": ["chat", "agent"]
        ]
        print("[Alerts] Subscribing to \(alertsSessionKey)")
        sendRequest(id: "3", method: "sessions.subscribe", params: params)
    }

    private func sendChatMessage(_ message: String) {
        // Include app context and VERY concise mode
        let appContext = PizzaState.shared.getAppContext()
        let prefixedMessage = "[ULTRA BRIEF: Reply in 1-2 SHORT sentences only. No lists, no details, no elaboration. Be like a text message.]\n[\(appContext)]\n\(message)"

        let params: [String: Any] = [
            "sessionKey": pizzaSessionKey,
            "message": prefixedMessage,
            "idempotencyKey": UUID().uuidString
        ]
        sendRequest(id: "2", method: "chat.send", params: params)
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

            // Add to history so it shows in chat panel
            state.addToHistory(role: "assistant", content: utf8String)

            // Check pizza position for bubble side
            var bubbleOnLeft = false
            if let appDelegate = NSApp.delegate as? AppDelegate,
               let screen = NSScreen.main {
                let panelX = appDelegate.panel.frame.midX
                bubbleOnLeft = panelX > screen.frame.midX
            }

            // Use queue system (no auto-dismiss)
            state.showOrQueueMessage(utf8String, bubbleOnLeft: bubbleOnLeft)
            state.mood = .surprised  // Get attention!
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
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize device identity first - triggers Keychain prompt before any network calls
        DeviceIdentity.shared.initialize()

        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        setupPanel()
        setupMenuBar()
        setupMainMenu()
        setupGlobalHotkey()

        // Watch for chat dialog trigger
        NotificationCenter.default.addObserver(forName: .showChatDialog, object: nil, queue: .main) { [weak self] _ in
            self?.showChat()
        }

        // Watch for history dialog trigger
        NotificationCenter.default.addObserver(forName: .showHistoryDialog, object: nil, queue: .main) { [weak self] _ in
            self?.showHistory()
        }

        // Watch for hide chat dialog trigger
        NotificationCenter.default.addObserver(forName: .hideChatDialog, object: nil, queue: .main) { [weak self] _ in
            self?.chatPopover?.close()
        }
    }

    func setupGlobalHotkey() {
        // Install event handler once
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .showChatDialog, object: nil)
            }
            return noErr
        }, 1, &eventType, nil, nil)

        // Register the hotkey from stored settings (default: ⌘⇧C)
        registerHotkey()
    }

    func registerHotkey() {
        // Unregister existing hotkey if any
        if let existingRef = hotKeyRef {
            UnregisterEventHotKey(existingRef)
            hotKeyRef = nil
        }

        // Get stored values or defaults (⌘⇧C)
        let keyCode = UInt32(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
        let modifiers = UInt32(UserDefaults.standard.integer(forKey: "hotkeyModifiers"))

        // Use defaults if not set
        let finalKeyCode = keyCode > 0 ? keyCode : 8  // 'C' key
        let finalModifiers = modifiers > 0 ? modifiers : UInt32(cmdKey | shiftKey)

        let hotKeyID = EventHotKeyID(signature: OSType(0x484D5343), id: 1)
        var newHotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(finalKeyCode, finalModifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &newHotKeyRef)

        if status == noErr {
            hotKeyRef = newHotKeyRef
            print(">>> Global hotkey registered (keyCode: \(finalKeyCode), modifiers: \(finalModifiers))")
        } else {
            print(">>> Failed to register hotkey: \(status)")
        }
    }

    @objc func setHotkey() {
        let alert = NSAlert()
        alert.messageText = "Set Global Hotkey"
        alert.informativeText = "Press the key combination you want to use to open chat.\n\nCurrent: \(currentHotkeyDescription())"
        alert.alertStyle = .informational

        // Create key recorder view
        let recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        recorder.onHotkeyRecorded = { [weak self] keyCode, modifiers in
            UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(modifiers), forKey: "hotkeyModifiers")
            self?.registerHotkey()
        }
        alert.accessoryView = recorder

        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Reset to Default")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            // Reset to default ⌘⇧C
            UserDefaults.standard.removeObject(forKey: "hotkeyKeyCode")
            UserDefaults.standard.removeObject(forKey: "hotkeyModifiers")
            registerHotkey()
        }
    }

    func currentHotkeyDescription() -> String {
        let keyCode = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        let modifiers = UserDefaults.standard.integer(forKey: "hotkeyModifiers")

        if keyCode == 0 && modifiers == 0 {
            return "⌘⇧C"
        }

        var parts: [String] = []
        if modifiers & controlKey != 0 { parts.append("⌃") }
        if modifiers & optionKey != 0 { parts.append("⌥") }
        if modifiers & shiftKey != 0 { parts.append("⇧") }
        if modifiers & cmdKey != 0 { parts.append("⌘") }

        let keyName = keyCodeToString(UInt16(keyCode))
        parts.append(keyName)

        return parts.joined()
    }

    func keyCodeToString(_ keyCode: UInt16) -> String {
        let keyMap: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N",
            46: "M", 49: "Space", 36: "↩", 48: "Tab", 51: "⌫", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return keyMap[keyCode] ?? "?"
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

        // Character submenu
        let characterMenuItem = NSMenuItem(title: "Character", action: nil, keyEquivalent: "")
        let characterSubmenu = NSMenu()

        for companion in CompanionType.allCases {
            let item = NSMenuItem(title: companion.rawValue, action: #selector(changeCharacter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = companion
            characterSubmenu.addItem(item)
        }

        characterMenuItem.submenu = characterSubmenu
        menu.addItem(characterMenuItem)

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

        let hotkeyItem = NSMenuItem(title: "Set Hotkey...", action: #selector(setHotkey), keyEquivalent: "")
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

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
            chatPopover?.behavior = .transient
            chatPopover?.animates = true
            chatPopover?.contentViewController = ChatPopoverController(pizzaState: pizzaState)
        }

        // Update size based on expanded state
        let isExpanded = UserDefaults.standard.bool(forKey: "showExpandedChat")
        chatPopover?.contentSize = NSSize(width: 320, height: isExpanded ? 450 : 100)

        if let popover = chatPopover {
            if popover.isShown {
                popover.close()
            } else {
                // Activate app to accept keyboard input
                NSApp.activate(ignoringOtherApps: true)

                // Show relative to the panel center
                let panelBounds = panel.contentView!.bounds
                let rect = NSRect(x: panelBounds.midX - 10, y: panelBounds.midY, width: 20, height: 20)
                popover.show(relativeTo: rect, of: panel.contentView!, preferredEdge: .maxY)

                // Make popover's window key for input focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    popover.contentViewController?.view.window?.makeKey()
                }
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

    @objc func changeCharacter(_ sender: NSMenuItem) {
        if let companion = sender.representedObject as? CompanionType {
            pizzaState.companionType = companion
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
    @State private var isExpanded: Bool = UserDefaults.standard.bool(forKey: "showExpandedChat")
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header with expand/collapse toggle
            HStack {
                Text("🍕 HomeSlice")
                    .font(.headline)
                Spacer()

                // Expand/collapse button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                        UserDefaults.standard.set(isExpanded, forKey: "showExpandedChat")
                    }
                }) {
                    HStack(spacing: 4) {
                        if !pizzaState.chatHistory.isEmpty {
                            Text("\(pizzaState.chatHistory.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)
                    }
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide history" : "Show history")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            // History section (collapsible)
            if isExpanded {
                Divider()

                if pizzaState.chatHistory.isEmpty {
                    VStack {
                        Spacer()
                        Text("No messages yet")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(height: 300)
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
                        .frame(height: 300)
                        .onChange(of: pizzaState.chatHistory.count) {
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
            }

            Divider()

            // Input area (always visible)
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
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
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
    static let hideChatDialog = Notification.Name("hideChatDialog")
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
                // Character body - pizza, cat, or jacob
                ZStack {
                    switch pizzaState.companionType {
                    case .pizza:
                        PizzaSlice()
                            .scaleEffect(breatheScale)
                        KawaiiFace(isBlinking: isBlinking, mood: pizzaState.mood)
                            .offset(y: 15)
                            .scaleEffect(breatheScale)
                    case .cat:
                        KawaiiCat(isBlinking: isBlinking, mood: pizzaState.mood)
                            .scaleEffect(breatheScale)
                    case .jacob:
                        KawaiiJacob(isBlinking: isBlinking, mood: pizzaState.mood)
                            .scaleEffect(breatheScale)
                    }
                }
                .rotationEffect(.degrees(wiggleAngle + spinAngle))

                // Speech bubble for mood
                if pizzaState.mood != .happy && !pizzaState.showChatInput && !pizzaState.chatDisplay.showResponse && !pizzaState.chatDisplay.isThinking {
                    SpeechBubble(mood: pizzaState.mood)
                        .offset(x: 50, y: -50)
                        .transition(.scale.combined(with: .opacity))
                }

                // Thinking indicator - same side as response but closer
                if pizzaState.chatDisplay.isThinking {
                    ThinkingBubble()
                        .offset(
                            x: pizzaState.chatDisplay.bubbleOnLeft ? -70 : 70,
                            y: -60
                        )
                }

                // Bot response bubble - position based on pizza screen location
                if pizzaState.chatDisplay.showResponse {
                    ResponseBubble(message: pizzaState.chatDisplay.botResponse)
                        .environmentObject(pizzaState)
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
    @EnvironmentObject var pizzaState: PizzaState
    let message: String
    var onLeft: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with close button
            HStack {
                // Queue badge if there are more messages
                if pizzaState.pendingMessageCount > 0 {
                    Text("+\(pizzaState.pendingMessageCount)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue))
                }

                Spacer()

                // Close button
                Button(action: {
                    pizzaState.dismissResponse()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Dismiss (shows next if queued)")
            }
            .padding(.bottom, 6)

            // Message content
            ScrollView {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.black)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Footer with actions
            HStack(spacing: 12) {
                // Open history button
                Button(action: {
                    pizzaState.dismissResponse()
                    NotificationCenter.default.post(name: .showChatDialog, object: nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                        Text("History")
                            .font(.caption2)
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)

                Spacer()

                // Dismiss all if queue has messages
                if pizzaState.pendingMessageCount > 0 {
                    Button(action: {
                        pizzaState.dismissAllResponses()
                    }) {
                        Text("Dismiss all")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 280)
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 4)
        )
    }
}

// MARK: - Kawaii Cat
// Inspired by classic kawaii cat design: big head, small bean body, triangle ears

struct KawaiiCat: View {
    let isBlinking: Bool
    let mood: PizzaMood

    // Soft gray cat colors with contrast between parts
    let headColor = Color(red: 0.72, green: 0.72, blue: 0.75)      // Medium gray - features visible
    let bodyColor = Color(red: 0.62, green: 0.62, blue: 0.66)      // Darker - body
    let tailColor = Color(red: 0.52, green: 0.52, blue: 0.56)      // Darkest - tail
    let tummyColor = Color(red: 0.85, green: 0.85, blue: 0.88)     // Light tummy patch
    let furDark = Color(red: 0.4, green: 0.4, blue: 0.45)          // For details/whiskers
    let earPink = Color(red: 1.0, green: 0.78, blue: 0.82)
    let noseColor = Color(red: 0.95, green: 0.7, blue: 0.75)

    var body: some View {
        ZStack {
            // === TAIL - behind everything (darkest) ===
            Circle()
                .trim(from: 0.5, to: 0.85)
                .stroke(tailColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: 45, height: 45)
                .offset(x: 42, y: 35)

            // === BODY - small bean/oval shape (medium) ===
            Ellipse()
                .fill(bodyColor)
                .frame(width: 55, height: 45)
                .offset(y: 42)

            // Tummy - lighter patch
            Ellipse()
                .fill(tummyColor)
                .frame(width: 35, height: 30)
                .offset(y: 42)

            // === LITTLE PAWS - two tiny ovals at front ===
            HStack(spacing: 4) {
                Ellipse().fill(bodyColor).frame(width: 16, height: 10)
                Ellipse().fill(bodyColor).frame(width: 16, height: 10)
            }
            .offset(y: 62)

            // === HEAD - big round circle (lightest - the star!) ===
            Circle()
                .fill(headColor)
                .frame(width: 80, height: 80)
                .offset(y: -10)

            // === EARS - soft triangles on TOP of head ===
            // Left ear
            KawaiiCatEar()
                .fill(headColor)
                .frame(width: 28, height: 32)
                .rotationEffect(.degrees(-15))
                .offset(x: -28, y: -45)
            // Left ear inner pink
            KawaiiCatEar()
                .fill(earPink)
                .frame(width: 14, height: 16)
                .rotationEffect(.degrees(-15))
                .offset(x: -28, y: -42)

            // Right ear
            KawaiiCatEar()
                .fill(headColor)
                .frame(width: 28, height: 32)
                .rotationEffect(.degrees(15))
                .offset(x: 28, y: -45)
            // Right ear inner pink
            KawaiiCatEar()
                .fill(earPink)
                .frame(width: 14, height: 16)
                .rotationEffect(.degrees(15))
                .offset(x: 28, y: -42)

            // === FACE ===
            // Big kawaii eyes
            HStack(spacing: 20) {
                // Left eye
                ZStack {
                    Ellipse()
                        .fill(Color.black)
                        .frame(width: isBlinking ? 18 : 18, height: isBlinking ? 3 : 20)
                    // Eye highlight
                    if !isBlinking {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 7, height: 7)
                            .offset(x: -3, y: -4)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 4, height: 4)
                            .offset(x: 3, y: 3)
                    }
                }
                // Right eye
                ZStack {
                    Ellipse()
                        .fill(Color.black)
                        .frame(width: isBlinking ? 18 : 18, height: isBlinking ? 3 : 20)
                    // Eye highlight
                    if !isBlinking {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 7, height: 7)
                            .offset(x: -3, y: -4)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 4, height: 4)
                            .offset(x: 3, y: 3)
                    }
                }
            }
            .offset(y: -15)

            // Tiny nose - small triangle/oval
            Ellipse()
                .fill(noseColor)
                .frame(width: 10, height: 7)
                .offset(y: 2)

            // Simple cat mouth :3
            HStack(spacing: 1) {
                // Left curve
                Circle()
                    .trim(from: 0.0, to: 0.5)
                    .stroke(furDark, lineWidth: 2)
                    .frame(width: 10, height: 10)
                // Right curve
                Circle()
                    .trim(from: 0.0, to: 0.5)
                    .stroke(furDark, lineWidth: 2)
                    .frame(width: 10, height: 10)
            }
            .offset(y: 12)

            // Rosy cheeks
            Circle()
                .fill(Color.pink.opacity(0.35))
                .frame(width: 14, height: 14)
                .offset(x: -25, y: 0)
            Circle()
                .fill(Color.pink.opacity(0.35))
                .frame(width: 14, height: 14)
                .offset(x: 25, y: 0)

            // Whiskers - 3 lines on each side (fanning outward)
            // Left whiskers
            Group {
                Rectangle()
                    .fill(furDark)
                    .frame(width: 20, height: 1.5)
                    .rotationEffect(.degrees(15))
                    .offset(x: -32, y: 0)
                Rectangle()
                    .fill(furDark)
                    .frame(width: 22, height: 1.5)
                    .offset(x: -33, y: 6)
                Rectangle()
                    .fill(furDark)
                    .frame(width: 20, height: 1.5)
                    .rotationEffect(.degrees(-15))
                    .offset(x: -32, y: 12)
            }
            // Right whiskers
            Group {
                Rectangle()
                    .fill(furDark)
                    .frame(width: 20, height: 1.5)
                    .rotationEffect(.degrees(-15))
                    .offset(x: 32, y: 0)
                Rectangle()
                    .fill(furDark)
                    .frame(width: 22, height: 1.5)
                    .offset(x: 33, y: 6)
                Rectangle()
                    .fill(furDark)
                    .frame(width: 20, height: 1.5)
                    .rotationEffect(.degrees(15))
                    .offset(x: 32, y: 12)
            }
        }
        .frame(width: 120, height: 140)
    }
}

// Soft rounded triangle ear shape
struct KawaiiCatEar: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Rounded triangle - curved edges for kawaii look
        path.move(to: CGPoint(x: rect.midX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height),
            control: CGPoint(x: rect.width * 0.1, y: rect.height * 0.4)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: rect.height),
            control: CGPoint(x: rect.midX, y: rect.height * 0.85)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: 0),
            control: CGPoint(x: rect.width * 0.9, y: rect.height * 0.4)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Kawaii Jacob
// Adapted from ChatGPT design - scaled to fit 120x140 frame

struct KawaiiJacob: View {
    let isBlinking: Bool
    let mood: PizzaMood

    // Colors
    let skinTone = Color(red: 0.97, green: 0.86, blue: 0.76)
    let hairColor = Color(red: 0.25, green: 0.16, blue: 0.10)
    let capColor = Color(red: 0.97, green: 0.94, blue: 0.90)
    let cardiganColor = Color(red: 0.47, green: 0.47, blue: 0.50)
    let beardDark = Color(red: 0.27, green: 0.20, blue: 0.15)
    let beardLight = Color(red: 0.18, green: 0.14, blue: 0.11)
    let rcPink = Color(red: 0.96, green: 0.42, blue: 0.55)

    var body: some View {
        ZStack {
            // === CARDIGAN (gray, behind everything) ===
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardiganColor)
                .frame(width: 85, height: 55)
                .offset(y: 52)

            // === HOODIE (white) ===
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .frame(width: 70, height: 50)
                .offset(y: 50)

            // Hood opening
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.05))
                .frame(width: 50, height: 28)
                .offset(y: 38)

            // Hoodie strings
            HStack(spacing: 8) {
                Capsule().fill(Color.black.opacity(0.12)).frame(width: 2, height: 18)
                Capsule().fill(Color.black.opacity(0.12)).frame(width: 2, height: 18)
            }
            .offset(y: 48)

            // RC on hoodie
            Text("RC")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundColor(rcPink)
                .offset(x: 20, y: 58)

            // === HAIR BACK ===
            JacobHairBlob()
                .fill(hairColor)
                .frame(width: 80, height: 65)
                .offset(y: -5)

            // Hair strands left
            JacobHairStrand()
                .fill(Color(red: 0.27, green: 0.17, blue: 0.11))
                .frame(width: 22, height: 40)
                .offset(x: -28, y: 12)

            // Hair strands right
            JacobHairStrand()
                .fill(Color(red: 0.27, green: 0.17, blue: 0.11))
                .frame(width: 22, height: 40)
                .scaleEffect(x: -1, y: 1)
                .offset(x: 28, y: 12)

            // === FACE ===
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [skinTone, Color(red: 0.95, green: 0.82, blue: 0.72)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 62, height: 55)
                .offset(y: -5)

            // Blush
            HStack(spacing: 30) {
                Circle().fill(Color.pink.opacity(0.22)).frame(width: 10, height: 8)
                Circle().fill(Color.pink.opacity(0.22)).frame(width: 10, height: 8)
            }
            .offset(y: 2)

            // === BEARD (the magnificent one) ===
            JacobBeardShape()
                .fill(
                    LinearGradient(
                        colors: [beardDark, beardLight],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 68, height: 50)
                .offset(y: 32)

            // Gray patches in beard
            Circle().fill(Color.white.opacity(0.45)).frame(width: 14, height: 11).blur(radius: 2).offset(x: -16, y: 22)
            Circle().fill(Color.white.opacity(0.38)).frame(width: 12, height: 10).blur(radius: 2).offset(x: 18, y: 20)
            Circle().fill(Color.white.opacity(0.30)).frame(width: 10, height: 8).blur(radius: 2).offset(x: 2, y: 30)

            // === HAT ===
            // Cap crown
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(capColor)
                .frame(width: 68, height: 38)
                .offset(y: -38)

            // Cap seams
            Path { p in
                p.move(to: CGPoint(x: 34, y: 6))
                p.addQuadCurve(to: CGPoint(x: 16, y: 34), control: CGPoint(x: 22, y: 16))
                p.move(to: CGPoint(x: 34, y: 6))
                p.addQuadCurve(to: CGPoint(x: 52, y: 34), control: CGPoint(x: 46, y: 16))
            }
            .stroke(Color.black.opacity(0.08), lineWidth: 1)
            .frame(width: 68, height: 38)
            .offset(y: -38)

            // Cap brim
            Capsule()
                .fill(Color(red: 0.95, green: 0.92, blue: 0.88))
                .frame(width: 68, height: 14)
                .offset(y: -20)

            // RC patch on cap
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(rcPink)
                .frame(width: 20, height: 14)
                .overlay(
                    Text("RC")
                        .font(.system(size: 7, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                )
                .offset(y: -40)

            // === GLASSES ===
            JacobGlasses()
                .offset(y: -8)
        }
        .frame(width: 120, height: 140)
    }
}

// Jacob's glasses with pupils and shine
struct JacobGlasses: View {
    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                JacobLens()
                JacobLens()
            }
            // Bridge
            Capsule()
                .fill(Color.black.opacity(0.45))
                .frame(width: 10, height: 3)
        }
    }
}

struct JacobLens: View {
    var body: some View {
        ZStack {
            // Lens
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.15, green: 0.12, blue: 0.18).opacity(0.85),
                            Color(red: 0.02, green: 0.02, blue: 0.03).opacity(0.95)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 16
                    )
                )
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 2))

            // Pupil
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: 12, height: 12)

            // Shine
            Circle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 5, height: 5)
                .offset(x: -4, y: -4)
        }
    }
}

// Hair blob shape
struct JacobHairBlob: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        p.move(to: CGPoint(x: w * 0.18, y: h * 0.35))
        p.addCurve(to: CGPoint(x: w * 0.28, y: h * 0.90),
                   control1: CGPoint(x: w * 0.02, y: h * 0.55),
                   control2: CGPoint(x: w * 0.10, y: h * 0.95))
        p.addCurve(to: CGPoint(x: w * 0.72, y: h * 0.90),
                   control1: CGPoint(x: w * 0.40, y: h * 0.86),
                   control2: CGPoint(x: w * 0.58, y: h * 1.02))
        p.addCurve(to: CGPoint(x: w * 0.82, y: h * 0.35),
                   control1: CGPoint(x: w * 0.90, y: h * 0.95),
                   control2: CGPoint(x: w * 0.98, y: h * 0.55))
        p.addCurve(to: CGPoint(x: w * 0.50, y: h * 0.08),
                   control1: CGPoint(x: w * 0.78, y: h * 0.18),
                   control2: CGPoint(x: w * 0.62, y: h * 0.06))
        p.addCurve(to: CGPoint(x: w * 0.18, y: h * 0.35),
                   control1: CGPoint(x: w * 0.38, y: h * 0.10),
                   control2: CGPoint(x: w * 0.22, y: h * 0.18))
        p.closeSubpath()
        return p
    }
}

// Hair strand shape
struct JacobHairStrand: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        p.move(to: CGPoint(x: w * 0.40, y: 0))
        p.addCurve(to: CGPoint(x: w * 0.18, y: h * 0.95),
                   control1: CGPoint(x: w * 0.05, y: h * 0.25),
                   control2: CGPoint(x: w * 0.02, y: h * 0.85))
        p.addCurve(to: CGPoint(x: w * 0.70, y: h * 0.78),
                   control1: CGPoint(x: w * 0.35, y: h * 1.02),
                   control2: CGPoint(x: w * 0.55, y: h * 0.95))
        p.addCurve(to: CGPoint(x: w * 0.40, y: 0),
                   control1: CGPoint(x: w * 0.92, y: h * 0.60),
                   control2: CGPoint(x: w * 0.88, y: h * 0.16))
        p.closeSubpath()
        return p
    }
}

// Beard shape
struct JacobBeardShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        p.move(to: CGPoint(x: w * 0.18, y: h * 0.18))
        p.addCurve(to: CGPoint(x: w * 0.08, y: h * 0.58),
                   control1: CGPoint(x: w * 0.06, y: h * 0.24),
                   control2: CGPoint(x: w * 0.02, y: h * 0.44))
        p.addCurve(to: CGPoint(x: w * 0.28, y: h * 0.92),
                   control1: CGPoint(x: w * 0.12, y: h * 0.80),
                   control2: CGPoint(x: w * 0.18, y: h * 0.94))
        p.addCurve(to: CGPoint(x: w * 0.50, y: h * 0.98),
                   control1: CGPoint(x: w * 0.35, y: h * 0.98),
                   control2: CGPoint(x: w * 0.44, y: h * 1.02))
        p.addCurve(to: CGPoint(x: w * 0.72, y: h * 0.92),
                   control1: CGPoint(x: w * 0.56, y: h * 1.02),
                   control2: CGPoint(x: w * 0.65, y: h * 0.98))
        p.addCurve(to: CGPoint(x: w * 0.92, y: h * 0.58),
                   control1: CGPoint(x: w * 0.82, y: h * 0.94),
                   control2: CGPoint(x: w * 0.88, y: h * 0.80))
        p.addCurve(to: CGPoint(x: w * 0.82, y: h * 0.18),
                   control1: CGPoint(x: w * 0.98, y: h * 0.44),
                   control2: CGPoint(x: w * 0.94, y: h * 0.24))
        p.addCurve(to: CGPoint(x: w * 0.50, y: h * 0.06),
                   control1: CGPoint(x: w * 0.74, y: h * 0.04),
                   control2: CGPoint(x: w * 0.60, y: h * 0.02))
        p.addCurve(to: CGPoint(x: w * 0.18, y: h * 0.18),
                   control1: CGPoint(x: w * 0.40, y: h * 0.02),
                   control2: CGPoint(x: w * 0.26, y: h * 0.04))
        p.closeSubpath()
        return p
    }
}

// MARK: - Hotkey Recorder

class HotkeyRecorderView: NSView {
    var onHotkeyRecorded: ((UInt32, UInt32) -> Void)?
    private var displayLabel: NSTextField!
    private var recordedKeyCode: UInt32 = 0
    private var recordedModifiers: UInt32 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        displayLabel = NSTextField(frame: bounds)
        displayLabel.isEditable = false
        displayLabel.isSelectable = false
        displayLabel.isBezeled = true
        displayLabel.bezelStyle = .roundedBezel
        displayLabel.alignment = .center
        displayLabel.stringValue = "Click here, then press keys..."
        displayLabel.font = NSFont.systemFont(ofSize: 13)
        addSubview(displayLabel)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        displayLabel.stringValue = "Press your hotkey..."
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])

        // Require at least one modifier
        guard !modifiers.isEmpty else {
            displayLabel.stringValue = "Need ⌘, ⌥, ⌃, or ⇧"
            return
        }

        recordedKeyCode = UInt32(event.keyCode)

        // Convert to Carbon modifier flags
        recordedModifiers = 0
        if modifiers.contains(.command) { recordedModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.option) { recordedModifiers |= UInt32(optionKey) }
        if modifiers.contains(.shift) { recordedModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.control) { recordedModifiers |= UInt32(controlKey) }

        // Build display string
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }

        let keyName = keyCodeToChar(event.keyCode)
        parts.append(keyName)

        displayLabel.stringValue = "Set to: " + parts.joined()

        onHotkeyRecorded?(recordedKeyCode, recordedModifiers)
    }

    private func keyCodeToChar(_ keyCode: UInt16) -> String {
        let keyMap: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N",
            46: "M", 49: "Space", 36: "↩", 48: "Tab", 51: "⌫", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return keyMap[keyCode] ?? "?"
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
