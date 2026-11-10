import SwiftUI

struct RegisterView: View {
    @EnvironmentObject var auth: AuthSession
    @Binding var mode: AuthMode
    @StateObject private var flow = RegisterFlow()
    @State private var hasSavedCode = false

    var body: some View {
        AuthScaffold(title: stepTitle, onBack: onBack) {
            switch flow.step {
            case .form: formStep
            case .confirmCode: confirmStep
            }
        }
    }

    private var stepTitle: String {
        flow.step == .form ? "Создать аккаунт" : "Сохраните код восстановления"
    }

    private var onBack: () -> Void {
        flow.step == .form ? { mode = .login } : { flow.step = .form }
    }

    // MARK: Шаг 1 — username и пароль

    private var formStep: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Username", text: Binding(get: { flow.username }, set: flow.usernameChanged))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .authFieldStyle()
                usernameHint
            }

            SecureField("Пароль", text: $flow.password).textContentType(.newPassword).authFieldStyle()
            SecureField("Повторите пароль", text: $flow.confirmPassword).textContentType(.newPassword).authFieldStyle()

            if let error = flow.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            AuthPrimaryButton(title: "Далее", isLoading: flow.isSubmitting, disabled: !flow.canSubmitForm) {
                Task { await flow.submitForm() }
            }
        }
    }

    @ViewBuilder
    private var usernameHint: some View {
        if flow.isCheckingUsername {
            Label("Проверяем…", systemImage: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        } else if let availability = flow.usernameAvailability {
            Label(availability.available ? "Свободно" : hintText(for: availability.reason),
                 systemImage: availability.available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(availability.available ? .green : .red)
        }
    }

    private func hintText(for reason: String?) -> String {
        switch reason {
        case "taken": return "Уже занято"
        case "reserved": return "Это имя зарезервировано"
        case "dot_at_edge": return "Точка не может быть в начале или в конце"
        case "consecutive_dots": return "Нельзя две точки подряд"
        default: return "От 3 до 30 символов: a-z, 0-9, _ и ."
        }
    }

    // MARK: Шаг 2 — подтверждение recovery-кода

    private var confirmStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
                Text(flow.recoveryCode ?? "")
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text("Это единственный способ восстановить пароль или username, если вы их забудете. Он больше нигде не показывается — сохраните его сейчас.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                if let code = flow.recoveryCode {
                    ShareLink(item: code) {
                        Label("Поделиться / сохранить", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(16)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Toggle("Я сохранил(а) код", isOn: $hasSavedCode)
                .font(.system(size: 14))
                .tint(Theme.accent)

            if hasSavedCode {
                VStack(spacing: 10) {
                    Text("Введите код ещё раз для подтверждения").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $flow.codeConfirmInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .authFieldStyle()
                }
                .transition(.opacity)
            }

            if let error = flow.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            AuthPrimaryButton(title: "Подтвердить и создать аккаунт", isLoading: flow.isSubmitting,
                              disabled: !hasSavedCode || flow.codeConfirmInput.isEmpty) {
                Task {
                    guard let pair = await flow.confirmCode() else { return }
                    await auth.completeRegistration(pair)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hasSavedCode)
    }
}
