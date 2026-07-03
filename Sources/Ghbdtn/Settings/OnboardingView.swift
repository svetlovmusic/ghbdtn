import SwiftUI

/// First-run guide that walks the user through granting Accessibility, which
/// the keystroke observer needs. Polls trust state live.
struct OnboardingView: View {
    let onDone: () -> Void
    @State private var trusted = Permissions.hasAccessibility()

    var body: some View {
        content
            // Explicit size: without it an unbounded Spacer makes the hosting
            // controller report a huge fitting height and the window stretches.
            .frame(width: 460, height: 430)
    }

    private var content: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Ghbdtn (Привет)")
                .font(.largeTitle.bold())
            Text("Автоматически исправляет текст, набранный не в той раскладке — прямо на лету.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Дайте доступ в **Универсальный доступ**, чтобы Ghbdtn мог видеть нажатия клавиш и исправлять раскладку.")
                } icon: {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "1.circle.fill")
                        .foregroundColor(trusted ? .green : .accentColor)
                }
                Text("Приложение работает **локально**. Нажатия анализируются в памяти и никуда не отправляются (кроме случая, когда вы сами включите облачный ИИ-слой).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            if trusted {
                Button {
                    onDone()
                } label: {
                    Text("Готово — включить").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            } else {
                Button {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                } label: {
                    Text("Открыть настройки доступа").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text("После включения Ghbdtn в списке — окно продолжит само.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(28)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            trusted = Permissions.hasAccessibility()
        }
    }
}
