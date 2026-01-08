import SwiftUI

struct CursorFAB: View {
    let onArrow: (ArrowDirection) -> Void
    let onEnter: () -> Void
    let onCtrlC: () -> Void

    enum ArrowDirection {
        case up, down, left, right
    }

    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero
    @State private var lastArrowSent: ArrowDirection?
    @State private var position: CGPoint = CGPoint(x: UIScreen.main.bounds.width - 50, y: UIScreen.main.bounds.height - 250)
    @State private var showingMenu = false

    // Threshold for registering a directional drag
    private let dragThreshold: CGFloat = 20
    // How far to drag before repeating
    private let repeatThreshold: CGFloat = 40

    var body: some View {
        ZStack {
            // Dismiss overlay when menu is showing
            if showingMenu {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            showingMenu = false
                        }
                    }
            }

            // Expanded menu (Ctrl+C, etc.)
            if showingMenu {
                expandedMenu
                    .transition(.scale.combined(with: .opacity))
            }

            // Main FAB
            Circle()
                .fill(isDragging ? Color.accentColor : Color(.systemGray5))
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .overlay {
                    Image(systemName: isDragging ? arrowIcon : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(isDragging ? .white : .primary)
                }
                .scaleEffect(isDragging ? 1.1 : 1.0)
                .offset(dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            handleDrag(value.translation)
                        }
                        .onEnded { _ in
                            endDrag()
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            onEnter()
                            hapticFeedback(.medium)
                        }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.3)) {
                                showingMenu.toggle()
                            }
                            hapticFeedback(.medium)
                        }
                )
                .position(position)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                // Reposition the FAB
                                position = value.location
                            }
                        }
                )
        }
    }

    private var arrowIcon: String {
        guard let direction = lastArrowSent else { return "arrow.up.left.and.arrow.down.right" }
        switch direction {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    private var expandedMenu: some View {
        HStack(spacing: 12) {
            MenuButton(icon: "escape", label: "esc") {
                showingMenu = false
            }
            MenuButton(icon: "arrow.right.to.line", label: "tab") {
                showingMenu = false
            }
            MenuButton(icon: "xmark.circle", label: "^C") {
                onCtrlC()
                showingMenu = false
            }
            MenuButton(icon: "stop.circle", label: "^D") {
                showingMenu = false
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .cornerRadius(28)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .position(x: position.x - 80, y: position.y - 70)
    }

    private func handleDrag(_ translation: CGSize) {
        isDragging = true
        dragOffset = CGSize(
            width: min(max(translation.width, -50), 50),
            height: min(max(translation.height, -50), 50)
        )

        // Determine direction based on drag
        let absX = abs(translation.width)
        let absY = abs(translation.height)

        // Only trigger if past threshold
        guard absX > dragThreshold || absY > dragThreshold else {
            lastArrowSent = nil
            return
        }

        let direction: ArrowDirection
        if absX > absY {
            direction = translation.width > 0 ? .right : .left
        } else {
            direction = translation.height > 0 ? .down : .up
        }

        // Send arrow if direction changed or past repeat threshold
        let shouldSend = lastArrowSent != direction ||
            absX > repeatThreshold || absY > repeatThreshold

        if shouldSend && lastArrowSent != direction {
            lastArrowSent = direction
            onArrow(direction)
            hapticFeedback(.light)
        }
    }

    private func endDrag() {
        withAnimation(.spring(response: 0.3)) {
            isDragging = false
            dragOffset = .zero
            lastArrowSent = nil
        }
    }

    private func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

struct MenuButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.primary)
            .frame(width: 44, height: 44)
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        CursorFAB(
            onArrow: { dir in print("Arrow: \(dir)") },
            onEnter: { print("Enter") },
            onCtrlC: { print("Ctrl+C") }
        )
    }
}
