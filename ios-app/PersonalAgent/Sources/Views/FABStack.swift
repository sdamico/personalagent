import SwiftUI
import Combine

struct FABStack: View {
    @Binding var isCursorDragging: Bool
    let isListening: Bool
    let hasError: Bool
    let onArrow: (CursorFAB.ArrowDirection) -> Void
    let onEnter: () -> Void
    let onCtrlKey: (Character) -> Void  // Generic Ctrl+<key>
    let onEscape: () -> Void
    let onTab: () -> Void
    let onBackspace: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onKeyboardToggle: () -> Void
    let onMicTap: () -> Void

    @State private var keyboardHeight: CGFloat = 0
    @State private var fabPosition: CGPoint = CGPoint(
        x: UIScreen.main.bounds.width - 80,  // More left to accommodate cursor controls
        y: UIScreen.main.bounds.height - 250
    )

    var body: some View {
        GeometryReader { geometry in
            // When keyboard is visible, position FAB just above it with small margin
            // When keyboard is hidden, use the saved position
            let adjustedY: CGFloat = {
                if keyboardHeight > 0 {
                    // Keyboard visible: position just above keyboard with 20pt margin
                    return geometry.size.height - keyboardHeight - 80
                } else {
                    // Keyboard hidden: use saved position, but keep on screen
                    return min(fabPosition.y, geometry.size.height - 120)
                }
            }()

            ZStack {
                // Mic FAB (below cursor FAB)
                if !isCursorDragging {
                    MicFAB(isListening: isListening, hasError: hasError, onTap: onMicTap)
                        .position(x: fabPosition.x, y: adjustedY + 70)
                        .transition(.scale.combined(with: .opacity))
                }

                // Cursor FAB
                CursorFABInternal(
                    isDragging: $isCursorDragging,
                    position: $fabPosition,
                    adjustedY: adjustedY,
                    keyboardHeight: keyboardHeight,
                    onArrow: onArrow,
                    onEnter: onEnter,
                    onCtrlKey: onCtrlKey,
                    onEscape: onEscape,
                    onTab: onTab,
                    onBackspace: onBackspace,
                    onCopy: onCopy,
                    onPaste: onPaste,
                    onKeyboardToggle: onKeyboardToggle
                )
            }
            .animation(.spring(response: 0.3), value: isCursorDragging)
            .animation(.spring(response: 0.3), value: keyboardHeight)
        }
        .onReceive(Publishers.keyboardHeight) { height in
            keyboardHeight = height
        }
    }
}

// MARK: - Mic FAB

struct MicFAB: View {
    let isListening: Bool
    let hasError: Bool
    let onTap: () -> Void

    @State private var isPulsing = false

    private var fillColor: Color {
        if hasError { return .orange }
        if isListening { return .red }
        return Color(.systemGray5)
    }

    private var iconName: String {
        if hasError { return "exclamationmark.triangle.fill" }
        if isListening { return "waveform" }
        return "mic.fill"
    }

    private var iconColor: Color {
        if hasError || isListening { return .white }
        return .accentColor
    }

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(fillColor)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .overlay {
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(iconColor)
                }
                .scaleEffect(isPulsing ? 1.1 : 1.0)
        }
        .onChange(of: isListening) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPulsing = false
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: fillColor)
    }
}

// MARK: - Cursor FAB Internal

struct CursorFABInternal: View {
    @Binding var isDragging: Bool
    @Binding var position: CGPoint
    let adjustedY: CGFloat
    let keyboardHeight: CGFloat
    let onArrow: (CursorFAB.ArrowDirection) -> Void
    let onEnter: () -> Void
    let onCtrlKey: (Character) -> Void
    let onEscape: () -> Void
    let onTab: () -> Void
    let onBackspace: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onKeyboardToggle: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var lastArrowSent: CursorFAB.ArrowDirection?
    @State private var showingMenu = false
    @State private var isRepositioning = false
    @State private var showingCtrlInput = false
    @State private var ctrlInputText = ""
    @FocusState private var ctrlInputFocused: Bool
    @StateObject private var repeatTimerManager = RepeatTimerManager()

    private let dragThreshold: CGFloat = 20

    var body: some View {
        ZStack {
            // Dismiss overlay when menu is showing
            if showingMenu || showingCtrlInput {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            showingMenu = false
                            showingCtrlInput = false
                            ctrlInputFocused = false
                        }
                    }
            }

            // Ctrl+ input field
            if showingCtrlInput {
                ctrlInputView
                    .position(x: position.x - 60, y: adjustedY - 60)
                    .transition(.scale.combined(with: .opacity))
            }

            // Expanded menu (esc, tab, ^C, ^D, ^+)
            if showingMenu && !showingCtrlInput {
                expandedMenu
                    .position(x: position.x - 160, y: adjustedY - 60)
                    .transition(.scale.combined(with: .opacity))
            }

            // Main FAB
            mainFAB
        }
    }

    private var mainFAB: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 56, height: 56)
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .overlay {
                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(iconColor)
            }
            .scaleEffect(scale)
            .offset(dragOffset)
            .position(x: position.x, y: adjustedY)
            .gesture(dragGesture)
            .simultaneousGesture(doubleTapGesture)
            .simultaneousGesture(longPressMenuGesture)
            .simultaneousGesture(tripleTapRepositionGesture)
    }

    private var fillColor: Color {
        if isRepositioning { return .orange }
        if isDragging { return .accentColor }
        return Color(.systemGray5)
    }

    private var iconName: String {
        if isRepositioning { return "arrow.up.and.down.and.arrow.left.and.right" }
        if isDragging { return arrowIcon }
        return "arrow.up.left.and.arrow.down.right"
    }

    private var iconColor: Color {
        (isRepositioning || isDragging) ? .white : .primary
    }

    private var scale: CGFloat {
        if isRepositioning { return 1.15 }
        if isDragging { return 1.1 }
        return 1.0
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
        VStack(spacing: 8) {
            // Top row: backspace, copy, paste, keyboard toggle
            HStack(spacing: 10) {
                MenuButton(icon: "delete.left", label: "del") {
                    onBackspace()
                    // Don't close menu - allow repeated backspaces
                }
                MenuButton(icon: "doc.on.doc", label: "copy") {
                    onCopy()
                    showingMenu = false
                }
                MenuButton(icon: "doc.on.clipboard", label: "paste") {
                    onPaste()
                    showingMenu = false
                }
                MenuButton(icon: keyboardHeight > 0 ? "keyboard.chevron.compact.down" : "keyboard", label: keyboardHeight > 0 ? "hide" : "kbd") {
                    onKeyboardToggle()
                    showingMenu = false
                }
            }
            // Bottom row: esc, tab, ^C, ^Z, ^?
            HStack(spacing: 10) {
                MenuButton(icon: "escape", label: "esc") {
                    onEscape()
                    showingMenu = false
                }
                MenuButton(icon: "arrow.right.to.line", label: "tab") {
                    onTab()
                    showingMenu = false
                }
                MenuButton(icon: "xmark.circle", label: "^C") {
                    onCtrlKey("c")
                    showingMenu = false
                }
                MenuButton(icon: "arrow.uturn.backward", label: "^Z") {
                    onCtrlKey("z")
                    showingMenu = false
                }
                MenuButton(icon: "character.cursor.ibeam", label: "^?") {
                    showingMenu = false
                    withAnimation(.spring(response: 0.3)) {
                        showingCtrlInput = true
                        ctrlInputText = ""
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        ctrlInputFocused = true
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private var ctrlInputView: some View {
        HStack(spacing: 8) {
            Text("^")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)

            TextField("", text: $ctrlInputText)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .frame(width: 30)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($ctrlInputFocused)
                .onChange(of: ctrlInputText) { _, newValue in
                    if let char = newValue.first {
                        onCtrlKey(char)
                        withAnimation(.spring(response: 0.3)) {
                            showingCtrlInput = false
                            ctrlInputFocused = false
                        }
                        ctrlInputText = ""
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if isRepositioning {
                    // Reposition mode - move the FAB
                    position = value.location
                } else {
                    // Normal mode - send arrow keys
                    isDragging = true
                    dragOffset = CGSize(
                        width: min(max(value.translation.width, -50), 50),
                        height: min(max(value.translation.height, -50), 50)
                    )

                    let absX = abs(value.translation.width)
                    let absY = abs(value.translation.height)

                    guard absX > dragThreshold || absY > dragThreshold else {
                        repeatTimerManager.stop()
                        lastArrowSent = nil
                        return
                    }

                    let direction: CursorFAB.ArrowDirection
                    if absX > absY {
                        direction = value.translation.width > 0 ? .right : .left
                    } else {
                        direction = value.translation.height > 0 ? .down : .up
                    }

                    if lastArrowSent != direction {
                        lastArrowSent = direction
                        onArrow(direction)
                        hapticFeedback(.light)

                        // Start repeat timer for this direction
                        repeatTimerManager.start(direction: direction, callback: onArrow)
                    }
                }
            }
            .onEnded { _ in
                repeatTimerManager.stop()
                withAnimation(.spring(response: 0.3)) {
                    isDragging = false
                    dragOffset = .zero
                    lastArrowSent = nil
                    isRepositioning = false
                }
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                onEnter()
                hapticFeedback(.medium)
            }
    }

    // Long press shows the special keys menu
    private var longPressMenuGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                withAnimation(.spring(response: 0.3)) {
                    showingMenu.toggle()
                }
                hapticFeedback(.medium)
            }
    }

    // Triple tap enters reposition mode (rarely needed)
    private var tripleTapRepositionGesture: some Gesture {
        TapGesture(count: 3)
            .onEnded {
                withAnimation(.spring(response: 0.3)) {
                    isRepositioning.toggle()
                }
                hapticFeedback(.medium)
            }
    }

    private func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

// MARK: - Repeat Timer Manager

class RepeatTimerManager: ObservableObject {
    private var timer: Timer?
    private var currentDirection: CursorFAB.ArrowDirection?
    private let repeatDelay: TimeInterval = 0.4
    private let repeatInterval: TimeInterval = 0.15  // Slower repeat for better control

    func start(direction: CursorFAB.ArrowDirection, callback: @escaping (CursorFAB.ArrowDirection) -> Void) {
        guard currentDirection != direction else { return }
        stop()
        currentDirection = direction

        // Initial delay before repeat starts
        timer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.currentDirection == direction else { return }
            // Switch to fast repeat
            self.timer = Timer.scheduledTimer(withTimeInterval: self.repeatInterval, repeats: true) { [weak self] _ in
                guard let self = self, self.currentDirection == direction else { return }
                callback(direction)
            }
            if let t = self.timer {
                RunLoop.main.add(t, forMode: .common)
            }
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentDirection = nil
    }
}

// MARK: - Keyboard Height Publisher

extension Publishers {
    static var keyboardHeight: AnyPublisher<CGFloat, Never> {
        let willShow = NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .map { notification -> CGFloat in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            }

        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ -> CGFloat in 0 }

        return MergeMany(willShow, willHide)
            .eraseToAnyPublisher()
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        FABStack(
            isCursorDragging: .constant(false),
            isListening: false,
            hasError: false,
            onArrow: { _ in },
            onEnter: {},
            onCtrlKey: { _ in },
            onEscape: {},
            onTab: {},
            onBackspace: {},
            onCopy: {},
            onPaste: {},
            onKeyboardToggle: {},
            onMicTap: {}
        )
    }
}
