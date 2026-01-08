import SwiftUI

struct SessionTabBar: View {
    @Binding var sessions: [PTYSession]
    @Binding var selectedSessionId: String?
    let isConnected: Bool
    let onNewSession: () -> Void
    let onCloseSession: (String) -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(sessions) { session in
                        SessionTab(
                            session: session,
                            isSelected: session.id == selectedSessionId,
                            onSelect: { selectedSessionId = session.id },
                            onClose: { onCloseSession(session.id) }
                        )
                    }

                    // New session button
                    Button(action: onNewSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.leading, 8)
            }

            // Connection status + Settings
            HStack(spacing: 12) {
                Circle()
                    .fill(isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                Button(action: onSettings) {
                    Image(systemName: "gear")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .background(Color(.systemBackground))
    }
}

struct SessionTab: View {
    let session: PTYSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 12))

                Text(session.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
            .foregroundColor(isSelected ? .accentColor : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
}

// MARK: - Preview

#Preview {
    SessionTabBar(
        sessions: .constant([
            PTYSession(id: "1", name: "Claude Code", cols: 80, rows: 24, cwd: "/", shell: "/bin/zsh", createdAt: 0),
            PTYSession(id: "2", name: "Terminal 2", cols: 80, rows: 24, cwd: "/", shell: "/bin/zsh", createdAt: 0),
        ]),
        selectedSessionId: .constant("1"),
        isConnected: true,
        onNewSession: {},
        onCloseSession: { _ in },
        onSettings: {}
    )
}
