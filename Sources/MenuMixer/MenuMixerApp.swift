import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement

@available(macOS 14.4, *)
@main
struct MenuMixerApp: App {
    @StateObject private var model = MixerModel()
    @StateObject private var loginStartup = LoginStartup()

    init() {
        if CommandLine.arguments.contains("--enable-login") || CommandLine.arguments.contains("--login-status") {
            do {
                let status = CommandLine.arguments.contains("--enable-login")
                    ? try LoginStartup.enable() : SMAppService.mainApp.status
                print("loginItem=\(LoginStartup.statusName(status))")
                print("app=\(Bundle.main.bundleURL.path)")
                exit(status == .enabled ? 0 : 2)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let result = try discoverAudio()
                print("출력: \(result.outputName) [\(result.outputID)]")
                let formats = try HAL.formats(result.outputID, scope: kAudioObjectPropertyScopeOutput)
                let inputs = try HAL.formats(result.outputID, scope: kAudioObjectPropertyScopeInput)
                print("출력 스트림: \(formats.count) · 물리 입력 스트림: \(inputs.count)")
                for f in formats { print("\(f.mSampleRate) Hz · \(f.mChannelsPerFrame) channels · float32=\(HAL.isFloatPCM(f))") }
                print("오디오 프로세스: \(result.processes.count)")
                let catalog = ApplicationCatalog(pids: result.processes.map(\.pid))
                for p in result.processes {
                    guard p.hasOutput else { continue }
                    let identity = catalog.identity(for: p)
                    print("PID \(p.pid) · raw=\(p.bundleID) · app=\(identity.id) · name=\(identity.name) · via=\(identity.source) · output=\(p.playing)")
                }
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MixerView(model: model, loginStartup: loginStartup)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .accessibilityLabel("Menu Mixer 앱별 볼륨")
        }
        .menuBarExtraStyle(.window)
    }
}

@available(macOS 14.4, *)
struct MixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var loginStartup: LoginStartup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Menu Mixer").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Label(model.outputName, systemImage: "hifispeaker.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).padding(5) }
                else {
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("앱 목록 새로고침")
                        .accessibilityLabel("앱 목록 새로고침")
                }
            }
            .padding(20)

            HStack {
                Text("앱별 볼륨").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.active.count)개 조절 중").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 10)

            if model.apps.isEmpty {
                VStack(spacing: 11) {
                    Image(systemName: "waveform").font(.system(size: 32, weight: .light)).foregroundStyle(.tint)
                    Text("소리를 재생해 보세요").font(.system(size: 14, weight: .semibold))
                    Text("음악이나 동영상을 재생하면\n오디오를 사용하는 앱이 여기에 나타납니다.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 34)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.apps) { app in appRow(app) }
                    }.padding(.horizontal, 16).padding(.vertical, 4)
                }.frame(height: min(CGFloat(model.apps.count) * 111 + 8, 390))
            }

            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(message).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("안내 닫기")
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16).padding(.top, 12)
            }

            Text("앱별 스위치를 켜면 볼륨 조절을 시작합니다.\n첫 사용 시 시스템 오디오 녹음 권한이 필요합니다. 소리는 저장하거나 전송하지 않습니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(20)

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Toggle("로그인 시 자동 실행", isOn: Binding(
                        get: { loginStartup.registered },
                        set: { loginStartup.setEnabled($0) }))
                        .toggleStyle(.switch).controlSize(.mini)
                    if loginStartup.needsApproval {
                        Button("승인 필요") { loginStartup.openSettings() }.buttonStyle(.borderless)
                    }
                }
                if let error = loginStartup.error {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("로그인 항목 설정 열기") { loginStartup.openSettings() }.buttonStyle(.borderless)
                }
            }.font(.system(size: 11)).padding(.horizontal, 20).padding(.top, 12)
            HStack {
                Button("모두 해제") { model.releaseAll() }
                    .disabled(!model.preferences.values.contains(where: \.enabled) || model.busy)
                Spacer()
                Button("종료") { model.quit() }.keyboardShortcut("q")
            }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(width: 370)
        .onAppear { loginStartup.refresh() }
    }

    private func appRow(_ app: MixerApp) -> some View {
        let settings = model.settings(app.id)
        let active = model.active.contains(app.id)
        let enabled = settings.enabled
        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30) }
                else { Image(systemName: "app.fill").font(.system(size: 28)).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(app.playing ? Color.green : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                        Text(active ? "볼륨 조절 중" : enabled ? "설정 유지 · 재연결 대기" : app.playing ? "오디오 사용 중" : "대기 중")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Toggle("\(app.name) 볼륨 조절", isOn: Binding(get: { enabled }, set: { model.toggle(app, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.busy)
            }
            HStack(spacing: 9) {
                Button { model.toggleMute(app.id) } label: {
                    Image(systemName: settings.muted || settings.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20).foregroundStyle(settings.muted ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain).help(settings.muted ? "음소거 해제" : "음소거")
                .accessibilityLabel("\(app.name) \(settings.muted ? "음소거 해제" : "음소거")")
                Slider(value: Binding(get: { settings.volume }, set: { model.setVolume(app.id, $0) }), in: 0...1)
                    .controlSize(.small).accessibilityLabel("\(app.name) 볼륨")
                    .accessibilityValue("\(Int(settings.volume * 100))퍼센트")
                Text(settings.muted ? "음소거" : "\(Int((settings.volume * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }.disabled(!enabled || model.busy).opacity(enabled ? 1 : 0.45)
        }
        .padding(13)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
