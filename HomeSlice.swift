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
}

enum ParticleType {
    case hearts
    case sparkles
    case stars
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    let pizzaState = PizzaState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        setupPanel()
        setupMenuBar()
    }

    func setupPanel() {
        // Create floating panel
        let panelSize = NSSize(width: 180, height: 220)
        panel = NSPanel(
            contentRect: NSRect(
                x: NSScreen.main!.frame.midX - panelSize.width / 2,
                y: NSScreen.main!.frame.midY - panelSize.height / 2,
                width: panelSize.width,
                height: panelSize.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configure panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        // Add SwiftUI content
        let hostingView = NSHostingView(rootView: KawaiiPizzaView().environmentObject(pizzaState))
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
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

        // Quit
        let quitItem = NSMenuItem(title: "Quit HomeSlice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
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
                .compositingGroup()
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
                .rotationEffect(.degrees(wiggleAngle + spinAngle))

                // Speech bubble outside so it doesn't clip
                if pizzaState.mood != .happy {
                    SpeechBubble(mood: pizzaState.mood)
                        .offset(x: 50, y: -50)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .offset(x: danceOffset, y: bobOffset + jumpOffset)
            .onTapGesture {
                handleTap()
            }
            .background(Color.clear)
            .contextMenu {
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
