import AppKit
import SwiftUI

@MainActor
@main
struct ScreenshotRenderer {
    static func main() {
        let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        render(
            view: PopupShowcaseView(),
            size: CGSize(width: 620, height: 610),
            to: outDir.appendingPathComponent("popup-hud.png")
        )

        render(
            view: TrainerShowcaseView(),
            size: CGSize(width: 760, height: 660),
            to: outDir.appendingPathComponent("english-trainer.png")
        )
    }

    static func render<V: View>(view: V, size: CGSize, to url: URL) {
        let wrapped = view
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2.0

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            fputs("Failed to render \(url.lastPathComponent)\n", stderr)
            exit(1)
        }
        try! png.write(to: url)
        print("Rendered \(url.path) (\(png.count) bytes)")
    }
}

private struct Backdrop<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.22),
                    Color(red: 0.14, green: 0.10, blue: 0.28),
                    Color(red: 0.07, green: 0.16, blue: 0.24)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
                .padding(28)
        }
    }
}

private struct TrafficLights: View {
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 0.15, green: 0.79, blue: 0.25)).frame(width: 11, height: 11)
            Spacer()
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
            Spacer()
            Color.clear.frame(width: 47, height: 11)
        }
        .padding(.bottom, 6)
    }
}

private struct PopupShowcaseView: View {
    var body: some View {
        Backdrop {
            VStack(alignment: .leading, spacing: 11) {
                // Header
                HStack(spacing: 8) {
                    Text("EN → RU")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.24), in: Capsule())
                        .foregroundColor(Color(red: 0.45, green: 0.72, blue: 1.0))

                    Text("0.5 сек • Qwen3.5-4B")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))

                    Spacer()

                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2.fill").foregroundColor(.white.opacity(0.85))
                        Image(systemName: "graduationcap.fill").foregroundColor(Color(red: 0.45, green: 0.72, blue: 1.0))
                        Image(systemName: "bookmark.fill").foregroundColor(.orange)
                        Image(systemName: "arrow.clockwise").foregroundColor(.white.opacity(0.7))
                        Image(systemName: "sparkles").foregroundColor(.white.opacity(0.7))
                    }
                    .font(.system(size: 13))
                }

                // Tone pills
                HStack(spacing: 6) {
                    pill("Деловой", active: true)
                    pill("Дружелюбный", active: false)
                    pill("Краткий", active: false)
                    pill("Нейтральный", active: false)
                }

                Divider().overlay(Color.white.opacity(0.12))

                // Translated text
                Text("Привет! Короткая сверка — мы всё ещё успеваем выкатить новый дашборд до завтрашнего демо?")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .lineSpacing(3)

                // Coach & Phrase Extractor box
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("AI English Coach", systemImage: "graduationcap.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(red: 0.45, green: 0.72, blue: 1.0))
                        Spacer()
                        Text("✓ Выражения извлечены")
                            .font(.system(size: 10.5))
                            .foregroundColor(.green)
                    }

                    Text("• on track — идти по графику (естественнее, чем «according to schedule»)\n• ship — выкатить релиз/фичу в прод (стандартный IT-сленг)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.86))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        phraseChip("on track", "идти по графику", saved: true)
                        phraseChip("quick check-in", "короткая сверка", saved: false)
                    }
                }
                .padding(11)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue.opacity(0.28), lineWidth: 1))

                // Context Reply drawer
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("Да, почти готово — нужно ещё пару часов на тесты")
                            .font(.system(size: 12.5))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
                    }

                    Text("Yes, we're almost there! We just need a couple more hours for final QA, and it'll be ready ahead of tomorrow's demo.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.72, green: 0.94, blue: 0.76))
                        .lineSpacing(2.5)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                Divider().overlay(Color.white.opacity(0.12))

                // Footer buttons
                HStack(spacing: 8) {
                    footerBtn("Копировать", icon: "doc.on.doc", primary: true)
                    footerBtn("Вставить ответ", icon: "arrow.down.doc", primary: false)
                    footerBtn("Ответить", icon: "arrowshape.turn.up.left", primary: false)
                    Spacer()
                    Text("⌃⌥P")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .padding(18)
            .background(Color(red: 0.13, green: 0.14, blue: 0.17).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        }
    }

    private func pill(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: active ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Color.blue : Color.white.opacity(0.09), in: Capsule())
            .foregroundColor(active ? .white : .white.opacity(0.8))
    }

    private func phraseChip(_ en: String, _ ru: String, saved: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(en).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white)
                Text(ru).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.65))
            }
            Spacer(minLength: 4)
            Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 12))
                .foregroundColor(saved ? .green : .orange)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func footerBtn(_ title: String, icon: String, primary: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(primary ? Color.blue : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .foregroundColor(.white)
    }
}

private struct TrainerShowcaseView: View {
    var body: some View {
        Backdrop {
            VStack(spacing: 12) {
                TrafficLights(title: "Тренажёр английского (SRS)  •  ⌃⌥L")

                // Top segmented tabs + streak
                HStack {
                    HStack(spacing: 2) {
                        seg("Тренировка (4)", active: true)
                        seg("💬 Диалог", active: false)
                        seg("Мой словарь (12)", active: false)
                    }
                    .padding(3)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Spacer()

                    HStack(spacing: 12) {
                        Label("5 дн.", systemImage: "flame.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.orange)
                        Label("28", systemImage: "checkmark.circle")
                            .font(.system(size: 12.5))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                Divider().overlay(Color.white.opacity(0.12))

                // Mode row
                HStack {
                    HStack(spacing: 2) {
                        seg("RU → EN", active: true)
                        seg("EN → RU", active: false)
                        seg("🎧 Аудирование", active: false)
                    }
                    .padding(3)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Text("Осталось: 4")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }

                // Prompt card
                VStack(alignment: .leading, spacing: 8) {
                    Text("Переведите на английский:")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    Text("Короткое предупреждение по срокам.")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                // User input
                HStack(spacing: 8) {
                    Text("A short warning about deadlines")
                        .font(.system(size: 13.5))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.75), lineWidth: 1.5))

                    Label("Проверить с ИИ", systemImage: "sparkles")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundColor(.white)
                }

                // Spacious AI Feedback card (unclipped!)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Оценка ИИ", systemImage: "sparkles")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.45, green: 0.72, blue: 1.0))

                    Text("🟡 Почти идеально\n• Смысл передан точно, но «warning» звучит слишком тревожно для деловой переписки с клиентом.\n• Носители обычно говорят «quick heads-up» и «timeline» вместо «deadlines».")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.92))
                        .lineSpacing(3.5)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.3), lineWidth: 1))

                // Reference Answer card + Kokoro Rust TTS
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Эталонный ответ:")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Label("Озвучить EN (Kokoro Rust)", systemImage: "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundColor(.white)
                        Text("🐢 0.75x")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundColor(.white)
                    }

                    Text("Just a quick heads-up regarding the timeline.")
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.42, green: 0.70, blue: 1.0))

                    Text("Заметка: Heads-up — вежливо предупредить клиента заранее")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.green.opacity(0.28), lineWidth: 1))

                // SRS buttons
                HStack(spacing: 12) {
                    srsBtn("Снова", sub: "10 мин", color: Color.red.opacity(0.22), fg: Color(red: 1.0, green: 0.48, blue: 0.45))
                    srsBtn("Хорошо", sub: "1 день", color: Color.blue, fg: .white)
                    srsBtn("Легко", sub: "2 дня", color: Color.green.opacity(0.22), fg: Color(red: 0.45, green: 0.90, blue: 0.55))
                }
            }
            .padding(18)
            .background(Color(red: 0.13, green: 0.14, blue: 0.17), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        }
    }

    private func seg(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: active ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(active ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundColor(active ? .white : .white.opacity(0.75))
    }

    private func srsBtn(_ title: String, sub: String, color: Color, fg: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(fg)
            Text(sub).font(.system(size: 10.5)).foregroundColor(fg.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(color, in: RoundedRectangle(cornerRadius: 9))
    }
}
