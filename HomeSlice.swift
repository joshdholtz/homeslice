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

class PizzaState: ObservableObject {
    static let shared = PizzaState()
    @Published var mood: PizzaMood = .happy
    @Published var isVisible: Bool = true
    @Published var showParticles: Bool = false
    @Published var particleType: ParticleType = .hearts

    // Chat state
    @Published var showChatInput: Bool = false
    @Published var chatMessage: String = ""
    @Published var botResponse: String = ""
    @Published var isThinking: Bool = false
    @Published var showResponse: Bool = false

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
    }

    func sendMessage() {
        guard !chatMessage.isEmpty, !botURL.isEmpty else { return }

        let message = chatMessage
        chatMessage = ""
        showChatInput = false
        isThinking = true
        mood = .excited

        GatewayClient.shared.send(message: message, to: botURL, token: botToken) { [weak self] response in
            DispatchQueue.main.async {
                self?.isThinking = false
                if let response = response {
                    self?.botResponse = response
                    self?.showResponse = true
                    self?.mood = .happy

                    // Hide response after 10 seconds (real responses may be longer)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        self?.showResponse = false
                        self?.botResponse = ""
                    }
                } else {
                    self?.mood = .surprised
                    self?.botResponse = "Couldn't reach bot!"
                    self?.showResponse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self?.showResponse = false
                        self?.botResponse = ""
                        self?.mood = .happy
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

    private let deviceIdKey = "homeslice.device.id"
    private let privateKeyTag = "homeslice.device.privateKey"

    var deviceId: String {
        if let stored = UserDefaults.standard.string(forKey: deviceIdKey) {
            return stored
        }
        let newId = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        return newId
    }

    private var _privateKey: Curve25519.Signing.PrivateKey?

    var privateKey: Curve25519.Signing.PrivateKey {
        if let key = _privateKey { return key }

        // Try to load from Keychain
        if let keyData = loadFromKeychain(tag: privateKeyTag),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            _privateKey = key
            return key
        }

        // Generate new key
        let newKey = Curve25519.Signing.PrivateKey()
        saveToKeychain(tag: privateKeyTag, data: newKey.rawRepresentation)
        _privateKey = newKey
        return newKey
    }

    var publicKeyBase64: String {
        Data(privateKey.publicKey.rawRepresentation).base64EncodedString()
    }

    func sign(nonce: String) -> String {
        guard let nonceData = nonce.data(using: .utf8) else { return "" }
        guard let signature = try? privateKey.signature(for: nonceData) else { return "" }
        return Data(signature).base64EncodedString()
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
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()

            case .failure(let error):
                print("WebSocket receive error: \(error.localizedDescription)")
                print("WebSocket state: \(self?.webSocket?.state.rawValue ?? -1)")
                // Try to get close code and reason
                if let urlError = error as? URLError {
                    print("URLError code: \(urlError.code.rawValue)")
                }
                let nsError = error as NSError
                print("Error domain: \(nsError.domain), code: \(nsError.code)")
                if let reason = nsError.userInfo["NSLocalizedDescription"] as? String {
                    print("Close reason: \(reason)")
                }
                self?.isConnected = false
                if self?.currentRunId == nil {
                    // Never got a successful chat response
                    self?.completion?(nil)
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
            // Extract assistant message content
            if let messages = payload["messages"] as? [[String: Any]] {
                for msg in messages {
                    if let role = msg["role"] as? String, role == "assistant",
                       let content = msg["content"] as? String {
                        responseBuffer = content
                    }
                }
            }
            // Check for completion
            if let status = payload["status"] as? String, status == "completed" {
                finishWithResponse()
            }

        case "agent":
            // Check for run completion
            if let status = payload["status"] as? String,
               (status == "completed" || status == "done") {
                finishWithResponse()
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
        let signature = device.sign(nonce: nonce)

        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "homeslice",
                "version": "1.0.0",
                "platform": "macos",
                "mode": "operator"
            ],
            "role": "operator",
            "scopes": ["operator.read", "operator.write"],
            "caps": [],
            "commands": [],
            "permissions": [:] as [String: Any],
            "locale": "en-US",
            "userAgent": "HomeSlice/1.0.0",
            "device": [
                "id": device.deviceId,
                "publicKey": device.publicKeyBase64,
                "signature": signature,
                "signedAt": ts,
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
        let params: [String: Any] = [
            "sessionKey": "main",
            "message": message,
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
        let response = responseBuffer.isEmpty ? "Done!" : responseBuffer
        DispatchQueue.main.async {
            self.completion?(response)
        }
        responseBuffer = ""
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
        let panelSize = NSSize(width: 600, height: 600)
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

        let configItem = NSMenuItem(title: "Configure Bot URL...", action: #selector(configureBotURL), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit HomeSlice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func showChat() {
        if chatPopover == nil {
            chatPopover = NSPopover()
            chatPopover?.contentSize = NSSize(width: 250, height: 50)
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

    @objc func toggleVisibility() {
        pizzaState.isVisible.toggle()
        if pizzaState.isVisible {
            panel.orderFrontRegardless()
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

// MARK: - Chat Popover Controller

class ChatPopoverController: NSViewController {
    let pizzaState: PizzaState
    var textField: NSTextField!

    init(pizzaState: PizzaState) {
        self.pizzaState = pizzaState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 50))

        textField = NSTextField(frame: NSRect(x: 10, y: 12, width: 190, height: 26))
        textField.placeholderString = "Ask me anything..."
        textField.bezelStyle = .roundedBezel
        textField.font = .systemFont(ofSize: 13)
        textField.target = self
        textField.action = #selector(sendMessage)
        container.addSubview(textField)

        let sendButton = NSButton(frame: NSRect(x: 205, y: 12, width: 35, height: 26))
        sendButton.title = "→"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        container.addSubview(sendButton)

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textField)
    }

    @objc func sendMessage() {
        let message = textField.stringValue
        guard !message.isEmpty else { return }

        pizzaState.chatMessage = message
        textField.stringValue = ""
        pizzaState.sendMessage()

        // Close popover after sending
        if let popover = (NSApp.delegate as? AppDelegate)?.chatPopover {
            popover.close()
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let doSpin = Notification.Name("doSpin")
    static let doJump = Notification.Name("doJump")
    static let doDance = Notification.Name("doDance")
    static let showChatDialog = Notification.Name("showChatDialog")
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
                if pizzaState.mood != .happy && !pizzaState.showChatInput && !pizzaState.showResponse && !pizzaState.isThinking {
                    SpeechBubble(mood: pizzaState.mood)
                        .offset(x: 50, y: -50)
                        .transition(.scale.combined(with: .opacity))
                }

                // Thinking indicator
                if pizzaState.isThinking {
                    ThinkingBubble()
                        .offset(x: 60, y: -60)
                        .transition(.scale.combined(with: .opacity))
                }

                // Bot response bubble
                if pizzaState.showResponse {
                    ResponseBubble(message: pizzaState.botResponse)
                        .offset(x: 70, y: -70)
                        .transition(.scale.combined(with: .opacity))
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
                    // Use menu bar chat which pops up a dialog
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
        .animation(.spring(response: 0.3), value: pizzaState.mood)
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
                .fill(.white)
                .shadow(radius: 3)
        )
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                dotCount = (dotCount + 1) % 4
            }
        }
    }
}

struct ResponseBubble: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundColor(.primary)
            .padding(10)
            .frame(maxWidth: 180)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white)
                    .shadow(radius: 3)
            )
            .fixedSize(horizontal: false, vertical: true)
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
