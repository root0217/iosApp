import SwiftUI
import UIKit

// MARK: - Главный экран

struct ChatScreen: View {
    @EnvironmentObject var store: ChatStore
    @State var text = ""
    @FocusState var focused: Bool
    let openDrawer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopBar(openDrawer: openDrawer) {
                store.newChat()
                text = ""
            }

            Group {
                if store.messages.isEmpty {
                    Color.clear
                } else {
                    MessageList()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { focused = false }

            InputBar(text: $text, focused: $focused) {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                store.send(text)
                text = ""
            }
        }
    }
}

// MARK: - Верхняя панель

struct TopBar: View {
    let openDrawer: () -> Void
    let newChat: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openDrawer) {
                VStack(alignment: .leading, spacing: 4.5) {
                    Capsule().frame(width: 15, height: 2)
                    Capsule().frame(width: 10, height: 2)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }

            Button { /* TODO */ } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold))
                    Text("Обновить")
                }
                .font(Typo.pill)
                .foregroundStyle(Theme.updateFg)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Theme.updateBg, in: Capsule())
            }

            Spacer()

            Button(action: newChat) {
                Image(systemName: "message")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 6)
        .frame(height: 44)
    }
}

// MARK: - Сообщения

struct MessageList: View {
    @EnvironmentObject var store: ChatStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(store.messages) { message in
                        MessageRow(message: message)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: message.isUser ? .bottomTrailing : .bottomLeading)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .animation(.easeOut(duration: 0.25), value: store.messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.messages.last?.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .font(Typo.body)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            HStack {
                if message.text.isEmpty {
                    TypingDot()
                } else {
                    Text(message.text)
                        .font(Typo.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct TypingDot: View {
    @State private var big = false

    var body: some View {
        Circle()
            .fill(.primary)
            .frame(width: 11, height: 11)
            .scaleEffect(big ? 1.0 : 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { big = true }
            }
    }
}

// MARK: - Поле ввода

struct InputBar: View {
    @EnvironmentObject var store: ChatStore
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trailingIcon: String {
        if store.isStreaming { return "stop.fill" }
        return hasText ? "arrow.up" : "waveform"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button { /* TODO: вложения */ } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .light))
                    .frame(width: 32, height: 32)
            }

            TextField(AppConfig.placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .font(Typo.input)
                .frame(minHeight: 32)

            if !hasText && !store.isStreaming {
                Button { /* TODO: диктовка */ } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 32, height: 32)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            Button(action: trailingAction) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: trailingIcon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .id(trailingIcon)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                .frame(width: 27, height: 27)
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 7.5)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .padding(.horizontal, 34)
        .padding(.bottom, 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: trailingIcon)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasText)
    }

    private func trailingAction() {
        if store.isStreaming {
            store.stop()
        } else if hasText {
            onSend()
        } else {
            // TODO: голосовой режим
        }
    }
}
