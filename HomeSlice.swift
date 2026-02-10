import AppKit
import SwiftUI
import Combine

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

    init() {
        self.botURL = UserDefaults.standard.string(forKey: "botURL") ?? ""
    }

    func sendMessage() {
        guard !chatMessage.isEmpty, !botURL.isEmpty else { return }

        let message = chatMessage
        chatMessage = ""
        showChatInput = false
        isThinking = true
        mood = .excited

        ChatService.shared.send(message: message, to: botURL) { [weak self] response in
            DispatchQueue.main.async {
                self?.isThinking = false
                if let response = response {
                    self?.botResponse = response
                    self?.showResponse = true
                    self?.mood = .happy

                    // Hide response after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
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

// MARK: - Chat Service

class ChatService {
    static let shared = ChatService()

    func send(message: String, to urlString: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["message": message]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = json["reply"] as? String else {
                completion(nil)
                return
            }
            completion(reply)
        }.resume()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    let pizzaState = PizzaState.shared
    var chatObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        setupPanel()
        setupMenuBar()
        setupMainMenu()

        // Watch for chat input to activate panel for keyboard
        chatObserver = pizzaState.$showChatInput.sink { [weak self] show in
            if show {
                self?.panel.makeKey()
                NSApp.activate(ignoringOtherApps: true)
            }
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
        pizzaState.showChatInput = true
    }

    @objc func configureBotURL() {
        let alert = NSAlert()
        alert.messageText = "Configure Bot URL"
        alert.informativeText = "Enter the URL for your bot (e.g., http://100.x.x.x:8080/chat)"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = pizzaState.botURL
        input.placeholderString = "http://your-bot-url/chat"
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            pizzaState.botURL = input.stringValue
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

// MARK: - Notifications

extension Notification.Name {
    static let doSpin = Notification.Name("doSpin")
    static let doJump = Notification.Name("doJump")
    static let doDance = Notification.Name("doDance")
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
                    pizzaState.showChatInput.toggle()
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
