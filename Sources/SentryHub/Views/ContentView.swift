import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            if let clip = appState.openClip {
                PlayerView(clip: clip) {
                    appState.closePlayer()
                }
                .transition(.opacity)
                // A fresh player per clip: rebuilding is cheaper and safer than
                // swapping every AVPlayer's item underneath the view.
                .id(clip.id)
            } else if appState.hasLibrary {
                LibraryView(library: appState.library)
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.openClip?.id)
        .overlay(ToastHostView())
        .overlay(UpdateProgressOverlay())
        .background(UpdateAlertHost(updates: appState.updates))
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            theme.glyph(size: 84)
                .padding(.bottom, 22)

            Text("Welcome to SentryHub")
                .font(.system(size: 34, weight: .bold))
            Text("Review Tesla Sentry, Saved, and Recent footage on your Mac —\nlocally, with every camera in sync.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            HStack(spacing: 14) {
                featureCard(
                    symbol: "rectangle.3.group.fill",
                    title: "Every Angle at Once",
                    detail: "Up to six camera feeds locked to one timeline"
                )
                featureCard(
                    symbol: "gauge.with.dots.needle.bottom.50percent",
                    title: "Customisable HUD",
                    detail: "Speed, gear, g-force, route — toggled element by element"
                )
                featureCard(
                    symbol: "square.and.arrow.up.fill",
                    title: "Trim & Export",
                    detail: "Cut a range and burn the HUD into an MP4"
                )
            }
            .padding(.top, 34)
            .padding(.horizontal, 40)
            .frame(maxWidth: 800)

            HStack(spacing: 12) {
                Button {
                    Task { await appState.library.chooseFolder() }
                } label: {
                    Text("Choose Your TeslaCam Folder")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(theme.primary)

                Button {
                    Task { await appState.library.loadSampleLibrary() }
                } label: {
                    HStack(spacing: 6) {
                        if appState.library.isBuildingSample {
                            ProgressView().controlSize(.small)
                        }
                        Text("Load Sample")
                            .font(.headline)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(appState.library.isBuildingSample)
            }
            .padding(.top, 36)

            if appState.library.isBuildingSample {
                VStack(spacing: 5) {
                    ProgressView(value: appState.library.sampleProgress)
                        .progressViewStyle(.linear)
                        .tint(theme.primary)
                        .frame(width: 260)
                    Text("Generating sample footage… \(Int(appState.library.sampleProgress * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.top, 14)
            } else {
                Text("Pick the dashcam drive, its TeslaCam folder, or any folder of clips you copied off it.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [theme.primary.opacity(0.10), Color.clear, theme.secondary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private func featureCard(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(theme.gradient)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .glassCard(cornerRadius: 14, padding: 14)
    }
}

// MARK: - Update chrome

struct UpdateAlertHost: View {
    @ObservedObject var updates: UpdateChecker

    private var isPresented: Binding<Bool> {
        Binding(
            get: {
                if case .updateAvailable = updates.status { return true }
                return false
            },
            set: { newValue in
                if !newValue { updates.status = .idle }
            }
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Update Available", isPresented: isPresented) {
                if case .updateAvailable(_, let url) = updates.status {
                    Button("Install & Relaunch") {
                        SelfUpdater.shared.install(from: url)
                    }
                }
                Button("Later", role: .cancel) {}
            } message: {
                if case .updateAvailable(let version, _) = updates.status {
                    Text("SentryHub \(version) is available. You are running \(AppVersion.current). Install now and the app will relaunch into the new version.")
                }
            }
    }
}

/// Full-window overlay shown while a self-update runs.
struct UpdateProgressOverlay: View {
    @ObservedObject private var updater = SelfUpdater.shared
    @Environment(\.appTheme) private var theme

    @State private var bobbing = false

    var body: some View {
        if updater.isBusy {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    theme.glyph(size: 60)
                        .offset(y: bobbing ? -5 : 5)
                        .animation(
                            .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                            value: bobbing
                        )

                    switch updater.phase {
                    case .downloading:
                        VStack(spacing: 7) {
                            ProgressView(value: updater.downloadProgress)
                                .progressViewStyle(.linear)
                                .tint(theme.primary)
                                .frame(width: 220)
                            Text("Downloading update… \(Int(updater.downloadProgress * 100))%")
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                        }
                    case .installing:
                        VStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                                .font(.callout.weight(.medium))
                        }
                    case .relaunching:
                        Text("Relaunching…")
                            .font(.callout.weight(.medium))
                    case .idle, .failed:
                        EmptyView()
                    }

                    Text("SentryHub will reopen automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 22, y: 8)
                .onAppear { bobbing = true }
            }
            .transition(.opacity)
        }
    }
}
