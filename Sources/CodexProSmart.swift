import SwiftUI
import AppKit
import Darwin

enum PublicConfiguration {
    static let controlScript = ProcessInfo.processInfo.environment["CODEXPRO_CONTROL_SCRIPT"]
        ?? "/usr/local/bin/codexpro-smart-control"

    static func host(for account: String) -> String {
        ProcessInfo.processInfo.environment["CODEXPRO_\(account.uppercased())_HOST"]
            ?? "line-\(account).example.invalid"
    }

    static func tokenPath(for account: String) -> String {
        let fallback = "~/.config/codexpro-smart/line-\(account)-token"
        let raw = ProcessInfo.processInfo.environment["CODEXPRO_\(account.uppercased())_TOKEN_FILE"] ?? fallback
        return (raw as NSString).expandingTildeInPath
    }
}

struct AccountStatus {
    let name: String
    let bindingNote: String
    var state = "stopped"
    var detail = "本机连接已关闭"
    var running = false
    var desiredOn = false
    var ready = false
    var tunnelCount = 0
    var serverCount = 0
    var cpu = 0.0
    var autostart = false
    var hostname = ""
    var port = 0

    var active: Bool {
        running || serverCount > 0 || tunnelCount > 0
    }
}

struct ServiceStatus {
    var state = "unknown"
    var detail = "状态未知，正在检查"
    var loaded = false
    var running = false
    var ready = false
    var autostart = false
    var autostartMixed = false
    var accountA = AccountStatus(name: "线路 A", bindingNote: "独立线路 · 可单独开启")
    var accountB = AccountStatus(name: "线路 B", bindingNote: "独立线路 · 可单独开启")

    var totalCPU: Double {
        accountA.cpu + accountB.cpu
    }
}

@MainActor
final class StatusModel: ObservableObject {
    static let shared = StatusModel()

    @Published var status = ServiceStatus()
    @Published var busy = false
    @Published var copyMessage = ""
    @Published var operationMessage = ""
    @Published var operationFailed = false

    private var timer: Timer?
    private nonisolated let control = PublicConfiguration.controlScript
    private nonisolated let commandQueue = DispatchQueue(label: "com.leo.codexpro.smart.commands", qos: .utility)
    private var refreshInFlight = false
    private var generation: UInt64 = 0

    private typealias CommandResult = ControlResult

    init() {
        refresh()
        scheduleRefresh(after: 15)
    }

    /// Bound both captured bytes and elapsed time, including inherited pipes.
    private nonisolated static func runControl(_ executable: String, _ args: [String], timeout: TimeInterval = 10) -> CommandResult {
        ControlRunner.run(executable, args, timeout: timeout)
    }

    private nonisolated static func parse(_ raw: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            if let index = line.firstIndex(of: "=") {
                values[String(line[..<index])] = String(line[line.index(after: index)...])
            }
        }
        return values
    }

    private nonisolated static func account(_ prefix: String, name: String, bindingNote: String, from values: [String: String]) -> AccountStatus {
        var result = AccountStatus(name: name, bindingNote: bindingNote)
        result.state = values["\(prefix)_state"] ?? "unknown"
        result.detail = values["\(prefix)_detail"] ?? "状态未知"
        result.running = values["\(prefix)_running"] == "true"
        result.ready = values["\(prefix)_ready"] == "true"
        result.tunnelCount = Int(values["\(prefix)_tunnel_count"] ?? "0") ?? 0
        result.serverCount = Int(values["\(prefix)_server_count"] ?? "0") ?? 0
        result.cpu = Double(values["\(prefix)_cloudflared_cpu"] ?? "0") ?? 0
        result.autostart = values["\(prefix)_autostart"] == "true"
        result.hostname = values["\(prefix)_hostname"] ?? ""
        result.port = Int(values["\(prefix)_port"] ?? "0") ?? 0
        result.desiredOn = values["\(prefix)_desired"].map { $0 == "true" } ?? result.active
        return result
    }

    private func scheduleRefresh(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func nextRefreshInterval(for state: ServiceStatus) -> TimeInterval {
        switch state.state {
        case "online": return 15
        case "connecting", "retrying", "stopping": return 2
        case "unknown", "partial", "failed": return 5
        default: return 30
        }
    }

    func refresh() {
        if refreshInFlight {
            // A command may still be stopping/starting launchd.  Retry later,
            // rather than starting a second status process concurrently.
            scheduleRefresh(after: 2)
            return
        }
        refreshInFlight = true
        let requestGeneration = generation

        let executable = control
        commandQueue.async { [weak self] in
            let result = Self.runControl(executable, ["machine"])
            let values = Self.parse(result.output)
            let valid = result.exitCode == 0 && !result.timedOut && !values.isEmpty

            var next = ServiceStatus()
            next.state = valid ? (values["state"] ?? "unknown") : "unknown"
            next.detail = valid
                ? (values["detail"] ?? "状态未知")
                : (result.timedOut ? "状态检查超时" : "状态检查失败")
            next.loaded = values["loaded"] == "true"
            next.running = values["running"] == "true"
            next.ready = values["ready"] == "true"
            next.autostart = values["autostart"] == "true"
            next.autostartMixed = values["autostart_mixed"] == "true"
            next.accountA = Self.account("a", name: "线路 A", bindingNote: "独立线路 · 可单独开启", from: values)
            next.accountB = Self.account("b", name: "线路 B", bindingNote: "独立线路 · 可单独开启", from: values)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                guard self.generation == requestGeneration else {
                    self.scheduleRefresh(after: 0.3)
                    return
                }
                self.status = next
                self.scheduleRefresh(after: self.nextRefreshInterval(for: next))
            }
        }
    }

    private func command(_ args: [String], timeout: TimeInterval = 45) {
        guard !busy else { return }
        busy = true
        generation &+= 1
        operationMessage = "正在提交操作…"
        operationFailed = false
        let executable = control
        commandQueue.async { [weak self] in
            let result = Self.runControl(executable, args, timeout: timeout)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                self.operationFailed = result.timedOut || result.exitCode != 0
                let summary = String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
                if result.timedOut {
                    self.operationMessage = "操作超时；未确认最终状态，请查看线路状态后再试。"
                } else if result.exitCode != 0 {
                    self.operationMessage = summary.isEmpty ? "操作失败（退出码 \(result.exitCode)），未确认成功。" : summary
                } else {
                    self.operationMessage = summary.isEmpty ? "请求已提交，请查看线路状态。" : summary
                }
                if result.truncated { self.operationMessage += "（输出已截断）" }
                self.refresh()
            }
        }
    }

    func setMaster(_ on: Bool) {
        command([on ? "on" : "off"], timeout: 120)
    }

    func stopAllConnections() {
        // Use the normal ownership-verified shutdown path; never terminate by
        // port or process name from the UI.
        command(["off"], timeout: 120)
    }

    func setAccount(_ account: String, on: Bool) {
        command([on ? "on-\(account)" : "off-\(account)"], timeout: 75)
    }

    func reconnect(_ account: String? = nil) {
        command([account.map { "restart-\($0)" } ?? "restart"], timeout: 120)
    }

    func diagnose() { command(["diagnose"], timeout: 15) }

    func setAutostart(_ on: Bool) {
        command(["autostart", on ? "on" : "off"], timeout: 10)
    }

    func copyServerURL(_ account: String) {
        let hostname = PublicConfiguration.host(for: account)
        let tokenPath = PublicConfiguration.tokenPath(for: account)
        do {
            let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 24 else { throw CocoaError(.validationMissingMandatoryProperty) }
            let url = "https://\(hostname)/mcp?codexpro_token=\(token)"
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            clipboard.setString(url, forType: .string)
            clipboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            clipboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let copiedChangeCount = clipboard.changeCount
            copyMessage = "线路 \(account.uppercased()) 地址已复制（含凭据）；60 秒后清除，请仅粘贴到对应连接设置。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                // Never erase something the user copied after this address.
                guard NSPasteboard.general.changeCount == copiedChangeCount else { return }
                NSPasteboard.general.clearContents()
                self?.copyMessage = "连接地址已从当前剪贴板清除。"
            }
        } catch {
            copyMessage = "账号 \(account.uppercased()) 的连接地址暂时无法读取。"
        }
    }
}

struct StatusBadge: View {
    let state: String

    private var text: String {
        switch state {
        case "online": return "线路就绪"
        case "partial": return "部分就绪"
        case "failed": return "异常"
        case "retrying": return "重试中"
        case "stopping": return "正在关闭"
        case "connecting": return "连接中"
        case "unknown": return "状态未知"
        default: return "已关闭"
        }
    }

    private var color: Color {
        switch state {
        case "online": return .green
        case "connecting", "retrying": return .orange
        case "partial", "unknown": return .yellow
        case "failed": return .red
        case "stopping": return .orange
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }
}

struct MenuBarLabel: View {
    let state: String

    private var symbol: String {
        switch state {
        case "online": return "terminal.fill"
        case "connecting": return "arrow.triangle.2.circlepath"
        case "retrying": return "arrow.clockwise"
        case "unknown": return "questionmark.circle"
        case "partial": return "exclamationmark.circle"
        case "failed": return "xmark.circle"
        case "stopping": return "hourglass"
        default: return "terminal"
        }
    }

    private var color: Color {
        switch state {
        case "online": return .green
        case "connecting", "retrying": return .orange
        case "partial", "unknown": return .yellow
        case "failed": return .red
        case "stopping": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .accessibilityLabel("CodexPro Smart，\(state)")
    }
}

struct AccountRow: View {
    let account: AccountStatus
    @Binding var isOn: Bool
    let busy: Bool
    let onReconnect: () -> Void
    let onCopyURL: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text(account.bindingNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(account.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(state: account.state)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(busy)
            }

            HStack(spacing: 8) {
                Label(account.ready ? "Tunnel 已就绪" : "Tunnel 未就绪",
                      systemImage: account.ready ? "checkmark.circle.fill" : "clock")
                Spacer()
                if !account.hostname.isEmpty {
                    Text(account.hostname)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("隧道 CPU \(String(format: "%.1f", account.cpu))%")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: onReconnect) {
                    Label(!account.desiredOn && account.active ? "重试关闭" : "重连", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(busy || (!account.active && !account.desiredOn))

                Button(action: onCopyURL) {
                    Label("复制 URL", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("复制这条线路的完整 MCP Server URL；token 不会显示在界面中")
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

struct ControlPanel: View {
    @ObservedObject var model: StatusModel
    let compact: Bool

    private var masterOn: Binding<Bool> {
        Binding(
            get: { model.status.accountA.desiredOn || model.status.accountB.desiredOn },
            set: { model.setMaster($0) }
        )
    }

    private var accountAOn: Binding<Bool> {
        Binding(
            get: { model.status.accountA.desiredOn },
            set: { model.setAccount("a", on: $0) }
        )
    }

    private var accountBOn: Binding<Bool> {
        Binding(
            get: { model.status.accountB.desiredOn },
            set: { model.setAccount("b", on: $0) }
        )
    }

    private var autostart: Binding<Bool> {
        Binding(
            get: { model.status.autostart },
            set: { model.setAutostart($0) }
        )
    }

    var body: some View {
        ScrollView {
        VStack(spacing: compact ? 13 : 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: compact ? 42 : 58, height: compact ? 42 : 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text("CodexPro Smart")
                        .font(.system(size: compact ? 18 : 24, weight: .bold))
                    Text("3.3 build 12 · 两条独立 MCP 线路 · \(model.status.detail)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()
                StatusBadge(state: model.status.state)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("总开关 · 两条线路")
                        .font(.system(size: 16, weight: .semibold))
                    Text("同时控制线路 A 和线路 B")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: masterOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.busy)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 13))

            VStack(spacing: 10) {
                AccountRow(
                    account: model.status.accountA,
                    isOn: accountAOn,
                    busy: model.busy,
                    onReconnect: { if !model.status.accountA.desiredOn && model.status.accountA.active { model.setAccount("a", on: false) } else { model.reconnect("a") } },
                    onCopyURL: { model.copyServerURL("a") }
                )
                AccountRow(
                    account: model.status.accountB,
                    isOn: accountBOn,
                    busy: model.busy,
                    onReconnect: { if !model.status.accountB.desiredOn && model.status.accountB.active { model.setAccount("b", on: false) } else { model.reconnect("b") } },
                    onCopyURL: { model.copyServerURL("b") }
                )
            }

            Button("只读诊断") { model.diagnose() }
                .controlSize(.small)
                .disabled(model.busy)
            Button(role: .destructive) {
                model.stopAllConnections()
            } label: {
                Label("关闭并结束全部后台线路", systemImage: "stop.circle")
            }
            .controlSize(.regular)
            .disabled(model.busy || (!model.status.accountA.desiredOn && !model.status.accountB.desiredOn && !model.status.accountA.active && !model.status.accountB.active))
            .help("通过 CodexPro Smart 的归属校验流程停止 A、B 两条线路及其隧道进程；不会退出或影响其他本机服务。")
            if model.status.autostartMixed {
                Text("A、B 登录自启设置不同；切换下方开关将统一设置。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("操作进行中，请勿重复点击。")
                        .font(.system(size: 11))
                }
            }
            if !model.operationMessage.isEmpty {
                Text(model.operationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(model.operationFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.copyMessage.isEmpty {
                Text(model.copyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Label(model.status.ready ? "当前开启的线路已就绪" : "请查看各线路状态",
                      systemImage: model.status.ready ? "checkmark.circle.fill" : "clock")
                Spacer()
                Text("隧道 CPU \(String(format: "%.1f", model.status.totalCPU))%")
                Text("A/B 独立 Tunnel")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录时自动开启")
                        .font(.system(size: 14, weight: .medium))
                    Text("默认关闭；打开后两条线路一起启动")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: autostart)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.busy)
            }

            Text("关闭会先等待在途请求；超时后仅对本应用已核验归属的进程强制收尾，不按端口或进程名误杀。线路就绪不等于 MCP 鉴权已验证。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if compact {
                Divider()
                Button("退出菜单栏控制器") {
                    NSApplication.shared.terminate(nil)
                }
                .foregroundStyle(.secondary)
                Text("仅退出控制界面，不会关闭已开启的线路。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(compact ? 16 : 22)
        }
        .frame(width: compact ? 430 : 650, height: compact ? 650 : 660)
    }
}

struct ContentView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        ControlPanel(model: model, compact: false)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlWindow: NSWindow?

    private func makeControlWindow() -> NSWindow {
        let controller = NSHostingController(rootView: ContentView(model: StatusModel.shared))
        let panel = NSWindow(contentViewController: controller)
        panel.title = "CodexPro Smart"
        panel.styleMask = [.titled, .closable, .miniaturizable]
        panel.setContentSize(NSSize(width: 650, height: 660))
        panel.minSize = NSSize(width: 650, height: 660)
        panel.isReleasedWhenClosed = false
        panel.center()
        return panel
    }

    private func revealControlPanel(in app: NSApplication) {
        DispatchQueue.main.async {
            let panel = self.controlWindow ?? self.makeControlWindow()
            self.controlWindow = panel
            panel.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.revealControlPanel(in: NSApplication.shared)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // A menu-bar app can already be running while its window is hidden.
        // Reusing the existing panel makes a second click on the app reliably
        // bring the controls to the front instead of appearing to do nothing.
        revealControlPanel(in: NSApplication.shared)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealControlPanel(in: sender)
        return true
    }
}

@main
struct CodexProSmartApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = StatusModel.shared

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model, compact: true)
        } label: {
            MenuBarLabel(state: model.status.state)
        }
        .menuBarExtraStyle(.window)
    }
}
