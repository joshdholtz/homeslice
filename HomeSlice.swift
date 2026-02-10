import AppKit
import SwiftUI
import Combine

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        // Create floating panel
        let panelSize = NSSize(width: 150, height: 180)
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
        let hostingView = NSHostingView(rootView: KawaiiPizzaView())
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        panel.orderFrontRegardless()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Kawaii Pizza View

struct KawaiiPizzaView: View {
    @State private var bobOffset: CGFloat = 0
    @State private var isBlinking = false
    @State private var breatheScale: CGFloat = 1.0
    @State private var wiggleAngle: Double = 0

    var body: some View {
        ZStack {
            // Main pizza slice
            PizzaSlice()
                .scaleEffect(breatheScale)

            // Kawaii face
            KawaiiFace(isBlinking: isBlinking)
                .offset(y: 15)
                .scaleEffect(breatheScale)
        }
        .rotationEffect(.degrees(wiggleAngle))
        .offset(y: bobOffset)
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .onAppear {
            startAnimations()
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
    }

    private func blink() {
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

    var body: some View {
        VStack(spacing: 8) {
            // Eyes
            HStack(spacing: 20) {
                KawaiiEye(isBlinking: isBlinking)
                KawaiiEye(isBlinking: isBlinking)
            }

            // Cheeks and smile
            ZStack {
                HStack(spacing: 35) {
                    // Rosy cheeks
                    Circle()
                        .fill(Color.pink.opacity(0.5))
                        .frame(width: 12, height: 12)

                    Circle()
                        .fill(Color.pink.opacity(0.5))
                        .frame(width: 12, height: 12)
                }

                // Smile
                SmilePath()
                    .stroke(Color(red: 0.4, green: 0.25, blue: 0.15), lineWidth: 2)
                    .frame(width: 15, height: 8)
                    .offset(y: 2)
            }
        }
    }
}

struct KawaiiEye: View {
    let isBlinking: Bool

    var body: some View {
        ZStack {
            // Eye white
            Ellipse()
                .fill(.white)
                .frame(width: 20, height: isBlinking ? 2 : 24)

            if !isBlinking {
                // Pupil
                Ellipse()
                    .fill(.black)
                    .frame(width: 12, height: 14)
                    .offset(y: 2)

                // Eye highlight (sparkle)
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
                    .offset(x: -3, y: -2)

                // Small secondary highlight
                Circle()
                    .fill(.white)
                    .frame(width: 3, height: 3)
                    .offset(x: 3, y: 4)
            }
        }
        .animation(.easeInOut(duration: 0.1), value: isBlinking)
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
