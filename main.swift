//
//  SplitTunnel — 菜单栏小应用
//
//  功能:
//    1. 内置 PAC 服务器 (127.0.0.1:9555), 动态生成 PAC 脚本
//    2. 拉起 SSH SOCKS5 隧道 (127.0.0.1:1080 -> joe-aliyun-hk-dev), 断线自动重连
//    3. 自动把系统 PAC 设置到当前活动网络服务 (不影响 fastup 等 TUN 型代理)
//
//  构建: swiftc -O -o SplitTunnel main.swift
//

import Cocoa
import Darwin
import SwiftUI

// MARK: - 常量与工具

let appLogPath = NSHomeDirectory() + "/Library/Logs/splittunnel-app.log"

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(msg)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let h = FileHandle(forWritingAtPath: appLogPath) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: appLogPath))
    }
}

/// 执行命令并返回 stdout (最多等 30s, 由 curl --max-time 兜底)
func shell(_ cmd: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do {
        try p.run()
    } catch {
        return ""
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// 端口是否已被占用 (TCP connect 探测 127.0.0.1)
func portInUse(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return true }
    defer { close(fd) }
    var flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if r == 0 { return true }
    if errno == EINPROGRESS {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&pfd, 1, 300)
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
    return true
}

// MARK: - 配置 (JSON, ~/Library/Application Support/SplitTunnel/config.json)

/// 配置值快照 (设置界面与 Config 之间传递)
struct ConfigValues {
    var hostAlias: String
    var keyComment: String
    var tunnelPortStart: Int
    var tunnelPortEnd: Int
    var serverAliveInterval: Int
    var connectTimeout: Int
    var retryIntervalSeconds: Double
    var sshVerbose: Bool
    var pacPortStart: Int
    var pacPortEnd: Int
    var proxyDomains: [String]
    var grafanaCheckURL: String
    var autoStartServices: Bool
    var autoApplySystemPAC: Bool
    var menuBarTitle: String

    static let defaults = ConfigValues(
        hostAlias: "joe-aliyun-hk-dev",
        keyComment: "joe_dev",
        tunnelPortStart: 1080,
        tunnelPortEnd: 1085,
        serverAliveInterval: 60,
        connectTimeout: 15,
        retryIntervalSeconds: 10.0,
        sshVerbose: true,
        pacPortStart: 9555,
        pacPortEnd: 9560,
        proxyDomains: ["bsquared.network"],
        grafanaCheckURL: "https://grafana.bsquared.network/",
        autoStartServices: true,
        autoApplySystemPAC: true,
        menuBarTitle: "🛰️"
    )
}

final class Config {
    static let shared = Config()

    let dir = NSHomeDirectory() + "/Library/Application Support/SplitTunnel"
    let path: String

    // ---- 默认值 (config.json 缺失或字段缺失时使用) ----
    var hostAlias = "joe-aliyun-hk-dev"          // ~/.ssh/config 里的主机别名
    var keyComment = "joe_dev"                   // 1Password agent 中要使用的公钥注释
    var tunnelPortStart = 1080                   // SSH SOCKS5 隧道端口范围
    var tunnelPortEnd = 1085
    var serverAliveInterval = 60                 // 秒, 隧道保活探测间隔
    var connectTimeout = 15                      // 秒, SSH 连接超时
    var retryIntervalSeconds = 10.0              // 秒, 隧道掉线后重试间隔
    var sshVerbose = true                        // ssh -v 调试日志写入 splittunnel-ssh.log
    var pacPortStart = 9555                      // 内置 PAC 服务器端口范围
    var pacPortEnd = 9560
    var proxyDomains = ["bsquared.network"]      // 走隧道的域名(后缀匹配), 其余一律直连
    var grafanaCheckURL = "https://grafana.bsquared.network/"  // 菜单栏状态检测地址
    var autoStartServices = true                 // 启动 App 时自动启动隧道+PAC 服务
    var autoApplySystemPAC = true                // 启动/重启服务时自动设置系统 PAC
    var menuBarTitle = "🛰️"                      // 菜单栏图标(服务正常时)

    var tunnelPortRange: ClosedRange<Int> { tunnelPortStart...max(tunnelPortEnd, tunnelPortStart) }
    var pacPortRange: ClosedRange<Int> { pacPortStart...max(pacPortEnd, pacPortStart) }

    private init() {
        path = dir + "/config.json"
    }

    /// 读取配置; 文件不存在时生成默认模板; 解析失败时保留默认值
    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            writeDefault()
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("config: 解析失败, 使用默认值")
            return
        }
        if let ssh = obj["ssh"] as? [String: Any] {
            hostAlias = (ssh["hostAlias"] as? String) ?? hostAlias
            keyComment = (ssh["keyComment"] as? String) ?? keyComment
            tunnelPortStart = (ssh["tunnelPortStart"] as? Int) ?? tunnelPortStart
            tunnelPortEnd = (ssh["tunnelPortEnd"] as? Int) ?? tunnelPortEnd
            serverAliveInterval = (ssh["serverAliveInterval"] as? Int) ?? serverAliveInterval
            connectTimeout = (ssh["connectTimeout"] as? Int) ?? connectTimeout
            retryIntervalSeconds = (ssh["retryIntervalSeconds"] as? Double) ?? retryIntervalSeconds
            sshVerbose = (ssh["verbose"] as? Bool) ?? sshVerbose
        }
        if let pac = obj["pac"] as? [String: Any] {
            pacPortStart = (pac["portStart"] as? Int) ?? pacPortStart
            pacPortEnd = (pac["portEnd"] as? Int) ?? pacPortEnd
        }
        proxyDomains = (obj["proxyDomains"] as? [String]) ?? proxyDomains
        grafanaCheckURL = (obj["grafanaCheckURL"] as? String) ?? grafanaCheckURL
        autoStartServices = (obj["autoStartServices"] as? Bool) ?? autoStartServices
        autoApplySystemPAC = (obj["autoApplySystemPAC"] as? Bool) ?? autoApplySystemPAC
        menuBarTitle = (obj["menuBarTitle"] as? String) ?? menuBarTitle
        log("config: 已加载 \(path)")
    }

    /// 当前值快照
    func values() -> ConfigValues {
        ConfigValues(
            hostAlias: hostAlias, keyComment: keyComment,
            tunnelPortStart: tunnelPortStart, tunnelPortEnd: tunnelPortEnd,
            serverAliveInterval: serverAliveInterval, connectTimeout: connectTimeout,
            retryIntervalSeconds: retryIntervalSeconds, sshVerbose: sshVerbose,
            pacPortStart: pacPortStart, pacPortEnd: pacPortEnd,
            proxyDomains: proxyDomains, grafanaCheckURL: grafanaCheckURL,
            autoStartServices: autoStartServices, autoApplySystemPAC: autoApplySystemPAC,
            menuBarTitle: menuBarTitle
        )
    }

    /// 用一组值覆盖当前配置
    func apply(_ v: ConfigValues) {
        hostAlias = v.hostAlias
        keyComment = v.keyComment
        tunnelPortStart = v.tunnelPortStart
        tunnelPortEnd = v.tunnelPortEnd
        serverAliveInterval = v.serverAliveInterval
        connectTimeout = v.connectTimeout
        retryIntervalSeconds = v.retryIntervalSeconds
        sshVerbose = v.sshVerbose
        pacPortStart = v.pacPortStart
        pacPortEnd = v.pacPortEnd
        proxyDomains = v.proxyDomains
        grafanaCheckURL = v.grafanaCheckURL
        autoStartServices = v.autoStartServices
        autoApplySystemPAC = v.autoApplySystemPAC
        menuBarTitle = v.menuBarTitle
    }

    func resetToDefaults() {
        apply(ConfigValues.defaults)
    }

    /// 生成带默认值的配置模板 (load 时文件缺失用)
    func writeDefault() {
        resetToDefaults()
        writeToDisk()
    }

    /// 把当前值写回 config.json
    func writeToDisk() {
        let template: [String: Any] = [
            "_comment": "SplitTunnel 配置。可通过菜单栏「设置…」界面修改, 也可直接编辑本文件后点「重新加载配置」。",
            "ssh": [
                "_comment": "SSH 隧道: hostAlias 为 ~/.ssh/config 主机别名; keyComment 为 1Password agent 中要用的公钥注释(每次连接仍会要求授权)",
                "hostAlias": hostAlias,
                "keyComment": keyComment,
                "tunnelPortStart": tunnelPortStart,
                "tunnelPortEnd": tunnelPortEnd,
                "serverAliveInterval": serverAliveInterval,
                "connectTimeout": connectTimeout,
                "retryIntervalSeconds": retryIntervalSeconds,
                "verbose": sshVerbose,
            ],
            "pac": [
                "_comment": "内置 PAC 服务器监听端口范围",
                "portStart": pacPortStart,
                "portEnd": pacPortEnd,
            ],
            "proxyDomains": proxyDomains,
            "grafanaCheckURL": grafanaCheckURL,
            "autoStartServices": autoStartServices,
            "autoApplySystemPAC": autoApplySystemPAC,
            "menuBarTitle": menuBarTitle,
        ]
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            log("config: 已写入 \(path)")
        } catch {
            log("config: 写配置失败: \(error)")
        }
    }
}

// MARK: - 设置界面 (SwiftUI)

struct SettingsView: View {
    let onSave: (ConfigValues) -> Void
    let onReset: () -> ConfigValues
    let onClose: () -> Void

    @State var hostAlias: String
    @State var keyComment: String
    @State var tunnelPortStart: String
    @State var tunnelPortEnd: String
    @State var serverAliveInterval: String
    @State var connectTimeout: String
    @State var retryIntervalSeconds: String
    @State var sshVerbose: Bool
    @State var pacPortStart: String
    @State var pacPortEnd: String
    @State var proxyDomainsText: String
    @State var grafanaCheckURL: String
    @State var autoStartServices: Bool
    @State var autoApplySystemPAC: Bool
    @State var menuBarTitle: String
    @State var statusMessage: String = ""

    init(values: ConfigValues,
         onSave: @escaping (ConfigValues) -> Void,
         onReset: @escaping () -> ConfigValues,
         onClose: @escaping () -> Void) {
        self.onSave = onSave
        self.onReset = onReset
        self.onClose = onClose
        _hostAlias = State(initialValue: values.hostAlias)
        _keyComment = State(initialValue: values.keyComment)
        _tunnelPortStart = State(initialValue: String(values.tunnelPortStart))
        _tunnelPortEnd = State(initialValue: String(values.tunnelPortEnd))
        _serverAliveInterval = State(initialValue: String(values.serverAliveInterval))
        _connectTimeout = State(initialValue: String(values.connectTimeout))
        _retryIntervalSeconds = State(initialValue: String(values.retryIntervalSeconds))
        _sshVerbose = State(initialValue: values.sshVerbose)
        _pacPortStart = State(initialValue: String(values.pacPortStart))
        _pacPortEnd = State(initialValue: String(values.pacPortEnd))
        _proxyDomainsText = State(initialValue: values.proxyDomains.joined(separator: "\n"))
        _grafanaCheckURL = State(initialValue: values.grafanaCheckURL)
        _autoStartServices = State(initialValue: values.autoStartServices)
        _autoApplySystemPAC = State(initialValue: values.autoApplySystemPAC)
        _menuBarTitle = State(initialValue: values.menuBarTitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("SSH 隧道") {
                    LabeledContent("主机别名 (~/.ssh/config)") {
                        TextField("joe-aliyun-hk-dev", text: $hostAlias)
                    }
                    LabeledContent("1Password 密钥注释") {
                        TextField("joe_dev", text: $keyComment)
                    }
                    LabeledContent("隧道端口范围") {
                        HStack(spacing: 6) {
                            TextField("1080", text: $tunnelPortStart)
                            Text("~")
                            TextField("1085", text: $tunnelPortEnd)
                        }
                    }
                    LabeledContent("保活间隔 (秒)") {
                        TextField("60", text: $serverAliveInterval)
                    }
                    LabeledContent("连接超时 (秒)") {
                        TextField("15", text: $connectTimeout)
                    }
                    LabeledContent("重试间隔 (秒)") {
                        TextField("10", text: $retryIntervalSeconds)
                    }
                    Toggle("输出 ssh 调试日志 (-v)", isOn: $sshVerbose)
                }
                Section("PAC 服务器") {
                    LabeledContent("PAC 端口范围") {
                        HStack(spacing: 6) {
                            TextField("9555", text: $pacPortStart)
                            Text("~")
                            TextField("9560", text: $pacPortEnd)
                        }
                    }
                }
                Section("分流 — 走隧道的域名 (每行一个, 后缀匹配)") {
                    TextEditor(text: $proxyDomainsText)
                        .frame(minHeight: 70)
                        .font(.system(.body, design: .monospaced))
                }
                Section("行为") {
                    LabeledContent("状态检测地址") {
                        TextField("https://grafana.bsquared.network/", text: $grafanaCheckURL)
                    }
                    Toggle("启动 App 时自动启动服务", isOn: $autoStartServices)
                    Toggle("自动设置系统 PAC", isOn: $autoApplySystemPAC)
                    LabeledContent("菜单栏图标") {
                        TextField("🛰️", text: $menuBarTitle)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("恢复默认") { reset() }
                Button("取消") { onClose() }
                Button("保存并应用") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 580, height: 680)
    }

    private func parsePort(_ s: String) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), n > 0, n < 65536 else { return nil }
        return n
    }

    private func save() {
        guard let tps = parsePort(tunnelPortStart),
              let tpe = parsePort(tunnelPortEnd),
              let sai = Int(serverAliveInterval.trimmingCharacters(in: .whitespaces)), sai > 0,
              let ct = Int(connectTimeout.trimmingCharacters(in: .whitespaces)), ct > 0,
              let ret = Double(retryIntervalSeconds.trimmingCharacters(in: .whitespaces)), ret > 0,
              let pps = parsePort(pacPortStart),
              let ppe = parsePort(pacPortEnd) else {
            statusMessage = "✗ 端口/数值字段格式不对, 请检查"
            return
        }
        let domains = proxyDomainsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let v = ConfigValues(
            hostAlias: hostAlias.trimmingCharacters(in: .whitespaces),
            keyComment: keyComment.trimmingCharacters(in: .whitespaces),
            tunnelPortStart: tps, tunnelPortEnd: tpe,
            serverAliveInterval: sai, connectTimeout: ct,
            retryIntervalSeconds: ret, sshVerbose: sshVerbose,
            pacPortStart: pps, pacPortEnd: ppe,
            proxyDomains: domains,
            grafanaCheckURL: grafanaCheckURL.trimmingCharacters(in: .whitespaces),
            autoStartServices: autoStartServices,
            autoApplySystemPAC: autoApplySystemPAC,
            menuBarTitle: menuBarTitle.isEmpty ? "🛰️" : menuBarTitle
        )
        onSave(v)
        statusMessage = "✓ 已保存并应用"
    }

    private func reset() {
        fill(onReset())
        statusMessage = "✓ 已恢复默认配置并应用"
    }

    private func fill(_ v: ConfigValues) {
        hostAlias = v.hostAlias
        keyComment = v.keyComment
        tunnelPortStart = String(v.tunnelPortStart)
        tunnelPortEnd = String(v.tunnelPortEnd)
        serverAliveInterval = String(v.serverAliveInterval)
        connectTimeout = String(v.connectTimeout)
        retryIntervalSeconds = String(v.retryIntervalSeconds)
        sshVerbose = v.sshVerbose
        pacPortStart = String(v.pacPortStart)
        pacPortEnd = String(v.pacPortEnd)
        proxyDomainsText = v.proxyDomains.joined(separator: "\n")
        grafanaCheckURL = v.grafanaCheckURL
        autoStartServices = v.autoStartServices
        autoApplySystemPAC = v.autoApplySystemPAC
        menuBarTitle = v.menuBarTitle
    }
}

// MARK: - SSH 隧道管理

final class TunnelManager {
    static let shared = TunnelManager()

    private(set) var running = false
    private(set) var port = Config.shared.tunnelPortRange.lowerBound
    private var process: Process?
    private var shouldRun = false
    private var retryTimer: Timer?
    var onStateChange: (() -> Void)?

    private init() {}

    var statusText: String {
        if running { return "● 运行中 (127.0.0.1:\(port))" }
        if shouldRun { return "◐ 启动中…" }
        return "○ 已停止"
    }

    func start() {
        shouldRun = true
        if process != nil && running {
            onStateChange?()
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        spawn()
    }

    func stop() {
        shouldRun = false
        retryTimer?.invalidate()
        retryTimer = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        running = false
        log("tunnel: 手动停止")
        onStateChange?()
    }

    /// 从 1Password SSH agent 动态导出指定注释的公钥。
    /// 只是"公钥指针", 私钥永远在 1Password 里, 每次连接仍会弹出授权框;
    /// 作用是限定 ssh 只向 agent 请求这一把钥匙 (避免多密钥撞服务器 MaxAuthTries)。
    /// agent 可能暂时未就绪(1Password 启动中/锁屏), 失败时重试几次。
    private func agentPubkeyPath() -> String? {
        var out = ""
        for attempt in 1...4 {
            out = shell("/usr/bin/ssh-add", ["-L"])
            if out.contains(Config.shared.keyComment) { break }
            if attempt < 4 {
                log("tunnel: agent 暂未返回密钥 [\(Config.shared.keyComment)], 1 秒后重试 (\(attempt)/3)")
                Thread.sleep(forTimeInterval: 1)
            }
        }
        let target = " " + Config.shared.keyComment
        for line in out.split(separator: "\n") {
            let l = String(line).trimmingCharacters(in: .whitespaces)
            if l.hasSuffix(target) {
                let dir = Config.shared.dir
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let path = dir + "/agent-key.pub"
                do {
                    try (l + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    return path
                } catch {
                    log("tunnel: 写公钥文件失败: \(error)")
                    return nil
                }
            }
        }
        log("tunnel: 1Password agent 中未找到密钥 [\(Config.shared.keyComment)] (检查 1Password 是否解锁或 keyComment 配置)")
        return nil
    }

    private func spawn() {
        for p in Config.shared.tunnelPortRange where !portInUse(p) {
            port = p
            break
        }
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = []
        if Config.shared.sshVerbose { args.append("-v") }
        args += [
            "-N",
            "-D", "127.0.0.1:\(port)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=\(Config.shared.serverAliveInterval)",
            "-o", "ConnectTimeout=\(Config.shared.connectTimeout)",
            "-o", "PreferredAuthentications=publickey",
            "-o", "BatchMode=yes",
        ]
        if let pk = agentPubkeyPath() {
            args += ["-i", pk, "-o", "IdentitiesOnly=yes"]
        }
        args.append(Config.shared.hostAlias)
        ssh.arguments = args
        ssh.standardOutput = FileHandle.nullDevice
        // stderr 进日志, 便于排障
        let sshLogPath = NSHomeDirectory() + "/Library/Logs/splittunnel-ssh.log"
        if !FileManager.default.fileExists(atPath: sshLogPath) {
            FileManager.default.createFile(atPath: sshLogPath, contents: nil)
        }
        if let h = FileHandle(forWritingAtPath: sshLogPath) {
            h.seekToEndOfFile()
            ssh.standardError = h
        } else {
            ssh.standardError = FileHandle.nullDevice
        }
        ssh.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                log("tunnel: ssh 退出, status=\(p.terminationStatus)")
                self.process = nil
                self.running = false
                if self.shouldRun {
                    self.retryTimer = Timer.scheduledTimer(withTimeInterval: Config.shared.retryIntervalSeconds, repeats: false) { [weak self] _ in
                        self?.spawn()
                    }
                }
                self.onStateChange?()
            }
        }
        do {
            try ssh.run()
            process = ssh
            running = true
            log("tunnel: ssh 已启动 (目标端口 127.0.0.1:\(port))")
            // 4 秒后校验端口, 未就绪则等授权; 16 秒仍未就绪则提示检查 1Password 授权框
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, self.process === ssh else { return }
                if portInUse(self.port) {
                    log("tunnel: ✓ 端口 127.0.0.1:\(self.port) 已就绪")
                } else {
                    log("tunnel: 认证中 (等待 1Password 授权)…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self = self, self.process === ssh else { return }
                        if portInUse(self.port) {
                            log("tunnel: ✓ 端口 127.0.0.1:\(self.port) 已就绪")
                        } else {
                            log("tunnel: ✗ 端口仍未绑定, 请检查 1Password 授权提示")
                        }
                    }
                }
                self.onStateChange?()
            }
        } catch {
            log("tunnel: 启动 ssh 失败: \(error)")
            process = nil
            running = false
            if shouldRun {
                retryTimer = Timer.scheduledTimer(withTimeInterval: Config.shared.retryIntervalSeconds, repeats: false) { [weak self] _ in
                    self?.spawn()
                }
            }
        }
        onStateChange?()
    }
}

// MARK: - 内置 PAC 服务器 (纯 POSIX socket)

final class PACServer {
    static let shared = PACServer()

    private(set) var running = false
    private(set) var port = Config.shared.pacPortRange.lowerBound
    private var listenFd: Int32 = -1
    private var thread: Thread?
    private var shouldStop = false
    var socksPortProvider: () -> Int = { Config.shared.tunnelPortRange.lowerBound }
    var onStateChange: (() -> Void)?

    private init() {}

    var statusText: String {
        running ? "● 运行中 (127.0.0.1:\(port))" : "○ 已停止"
    }

    var url: String {
        "http://127.0.0.1:\(port)/proxy.pac"
    }

    func start() {
        if running { return }
        for p in Config.shared.pacPortRange {
            if let fd = tryListen(p) {
                listenFd = fd
                port = p
                break
            }
        }
        guard listenFd >= 0 else {
            log("pac: \(Config.shared.pacPortRange) 端口全部被占用, 无法启动 (可修改 config.json 的 pac.portStart/End)")
            return
        }
        shouldStop = false
        running = true
        thread = Thread(block: { [weak self] in self?.serveLoop() })
        thread?.name = "pac-server"
        thread?.start()
        log("pac: 服务器已启动 \(url)")
        onStateChange?()
    }

    func stop() {
        shouldStop = true
        if listenFd >= 0 {
            shutdown(listenFd, SHUT_RDWR)
            close(listenFd)
            listenFd = -1
        }
        running = false
        log("pac: 服务器已停止")
        onStateChange?()
    }

    private func tryListen(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// 动态生成 PAC: 隧道端口实时取, 走隧道的域名列表来自配置
    private func pacBody() -> String {
        let socks = socksPortProvider()
        var conds: [String] = []
        for d in Config.shared.proxyDomains {
            let t = d.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                conds.append("host === \"\(t)\" || shExpMatch(host, \"*.\(t)\")")
            }
        }
        let cond = conds.isEmpty ? "false" : conds.joined(separator: " ||\n            ")
        return """
        function FindProxyForURL(url, host) {
            if (isPlainHostName(host) || host === "127.0.0.1" || host === "localhost" || host === "::1" || shExpMatch(host, "*.local")) {
                return "DIRECT";
            }
            if (\(cond)) {
                return "SOCKS5 127.0.0.1:\(socks)";
            }
            return "DIRECT";
        }
        """
    }

    private func serveLoop() {
        while !shouldStop {
            var pfd = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 500)
            if pr <= 0 { continue }
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFd, $0, &len)
                }
            }
            if cfd < 0 { continue }
            handle(cfd)
        }
        log("pac: 服务循环退出")
    }

    private func handle(_ cfd: Int32) {
        // accept 出来的 fd 继承了监听 socket 的非阻塞标志, 先切回阻塞模式
        var fl = fcntl(cfd, F_GETFL, 0)
        _ = fcntl(cfd, F_SETFL, fl & ~O_NONBLOCK)
        // 读超时 5s, 防止坏客户端把整个服务线程卡死
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 2048)
        let n = read(cfd, &buf, buf.count)
        var ok = false
        if n > 0, let req = String(bytes: buf[0..<n], encoding: .utf8) {
            ok = req.hasPrefix("GET ") && req.contains("/proxy.pac")
        }
        let body = ok ? pacBody() : "not found"
        let head = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\n" +
            "Content-Type: application/x-ns-proxy-autoconfig\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n"
        var resp = Array(head.utf8) + Array(body.utf8)
        resp.withUnsafeBufferPointer { ptr in
            _ = send(cfd, ptr.baseAddress!, ptr.count, 0)
        }
        close(cfd)
    }
}

// MARK: - 系统 PAC 管理 (通过 networksetup)

final class SystemProxy {
    static let shared = SystemProxy()

    private init() {}

    /// 当前活动网络服务名 (如 "Wi-Fi")
    func activeService() -> String? {
        let routeOut = shell("/sbin/route", ["-n", "get", "default"])
        guard let line = routeOut.split(separator: "\n").first(where: { $0.contains("interface:") }),
              let iface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        let ports = shell("/usr/sbin/networksetup", ["-listallhardwareports"])
            .split(separator: "\n").map(String.init)
        for i in 1..<ports.count where ports[i].hasPrefix("Device:") && ports[i].contains(iface) {
            if ports[i - 1].hasPrefix("Hardware Port:") {
                return String(ports[i - 1].dropFirst("Hardware Port:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func apply() {
        guard let svc = activeService() else {
            log("sysproxy: 未找到活动网络服务")
            return
        }
        let url = PACServer.shared.url
        _ = shell("/usr/sbin/networksetup", ["-setautoproxyurl", svc, url])
        _ = shell("/usr/sbin/networksetup", ["-setautoproxystate", svc, "on"])
        log("sysproxy: 已应用 PAC 到 [\(svc)] \(url)")
    }

    /// (是否已启用且指向本 App, 服务名)
    func isEnabled() -> (Bool, String) {
        guard let svc = activeService() else { return (false, "无网络") }
        let out = shell("/usr/sbin/networksetup", ["-getautoproxyurl", svc])
        let ours = out.contains(PACServer.shared.url)
        let enabled = out.contains("Enabled: Yes")
        return (enabled && ours, svc)
    }

    /// 退出时: 只撤销我们自己设置的 PAC, 不碰用户其它设置
    func removeIfOurs() {
        guard let svc = activeService() else { return }
        let out = shell("/usr/sbin/networksetup", ["-getautoproxyurl", svc])
        if out.contains(PACServer.shared.url) {
            _ = shell("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
            log("sysproxy: 已撤销 [\(svc)] 上的 PAC")
        }
    }
}

// MARK: - AppDelegate: 菜单栏 UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var grafanaItem: NSMenuItem?
    private var grafanaCheckGeneration = 0
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.joe.splittunnel")
        if instances.count > 1 {
            log("另一个实例已在运行, 本实例退出")
            NSApp.terminate(nil)
            return
        }

        Config.shared.load()
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()

        PACServer.shared.socksPortProvider = { TunnelManager.shared.port }
        PACServer.shared.onStateChange = { [weak self] in self?.refreshStatus() }
        TunnelManager.shared.onStateChange = { [weak self] in self?.refreshStatus() }

        log("========== SplitTunnel 启动 ==========")
        if CommandLine.arguments.contains("--settings") {
            actionOpenSettings()
        }
        if Config.shared.autoStartServices {
            startAll()
        } else {
            log("config: autoStartServices=false, 服务未自动启动 (菜单栏点「启动服务」)")
            refreshStatus()
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TunnelManager.shared.stop()
        PACServer.shared.stop()
        SystemProxy.shared.removeIfOurs()
        log("========== SplitTunnel 退出 ==========")
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = Config.shared.menuBarTitle
        menu.delegate = self
        statusItem.menu = menu
    }

    private func startAll() {
        PACServer.shared.start()
        TunnelManager.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if Config.shared.autoApplySystemPAC {
                SystemProxy.shared.apply()
            }
            self?.refreshStatus()
        }
    }

    private func stopAll() {
        TunnelManager.shared.stop()
        PACServer.shared.stop()
        refreshStatus()
    }

    private func refreshStatus() {
        let up = TunnelManager.shared.running && PACServer.shared.running
        statusItem.button?.title = up ? Config.shared.menuBarTitle : "⚠️"
    }

    // MARK: 菜单构建

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        buildMenu()
        scheduleGrafanaCheck()
    }

    private func buildMenu() {
        let header = NSMenuItem(title: "SplitTunnel — 域名分流隧道", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let t = NSMenuItem(title: "SSH 隧道 [\(Config.shared.hostAlias)]: \(TunnelManager.shared.statusText)", action: nil, keyEquivalent: "")
        t.isEnabled = false
        menu.addItem(t)

        let p = NSMenuItem(title: "PAC 服务: \(PACServer.shared.statusText)", action: nil, keyEquivalent: "")
        p.isEnabled = false
        menu.addItem(p)

        let (pacOn, svc) = SystemProxy.shared.isEnabled()
        let s = NSMenuItem(title: "系统 PAC: \(pacOn ? "● 已启用" : "○ 未启用")  [\(svc)]", action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)

        let g = NSMenuItem(title: "目标站点: 检测中…", action: nil, keyEquivalent: "")
        g.isEnabled = false
        grafanaItem = g
        menu.addItem(g)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(actionOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let allUp = TunnelManager.shared.running && PACServer.shared.running
        let toggle = NSMenuItem(title: allUp ? "停止服务" : "启动服务", action: #selector(actionToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let apply = NSMenuItem(title: "重新应用系统 PAC", action: #selector(actionApplyPAC), keyEquivalent: "")
        apply.target = self
        menu.addItem(apply)

        let openG = NSMenuItem(title: "打开目标站点", action: #selector(actionOpenGrafana), keyEquivalent: "")
        openG.target = self
        menu.addItem(openG)

        menu.addItem(.separator())

        let openLog = NSMenuItem(title: "打开日志", action: #selector(actionOpenLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        let openCfg = NSMenuItem(title: "打开配置文件", action: #selector(actionOpenConfig), keyEquivalent: "")
        openCfg.target = self
        menu.addItem(openCfg)

        let reloadCfg = NSMenuItem(title: "重新加载配置", action: #selector(actionReloadConfig), keyEquivalent: "")
        reloadCfg.target = self
        menu.addItem(reloadCfg)

        let quit = NSMenuItem(title: "退出", action: #selector(actionQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func scheduleGrafanaCheck() {
        grafanaCheckGeneration += 1
        let gen = grafanaCheckGeneration
        let port = TunnelManager.shared.port
        let checkURL = Config.shared.grafanaCheckURL
        grafanaItem?.title = "目标站点: 检测中…"
        DispatchQueue.global().async { [weak self] in
            let code = shell("/usr/bin/curl", [
                "-s", "-o", "/dev/null", "-w", "%{http_code}",
                "-x", "socks5h://127.0.0.1:\(port)",
                "--max-time", "8",
                checkURL,
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self = self, gen == self.grafanaCheckGeneration else { return }
                let text: String
                switch code {
                case "302", "200", "301", "401":
                    text = "目标站点: ✓ 可访问 (\(code))"
                case "403":
                    text = "目标站点: ✗ 被白名单拦截 (403)"
                default:
                    text = "目标站点: ? 无法访问 (\(code.isEmpty ? "超时" : code))"
                }
                self.grafanaItem?.title = text
            }
        }
    }

    // MARK: 菜单动作

    @objc func actionToggle() {
        if TunnelManager.shared.running || PACServer.shared.running {
            stopAll()
        } else {
            startAll()
        }
    }

    @objc func actionApplyPAC() {
        SystemProxy.shared.apply()
        refreshStatus()
    }

    @objc func actionOpenGrafana() {
        NSWorkspace.shared.open(URL(string: Config.shared.grafanaCheckURL)!)
    }

    @objc func actionOpenConfig() {
        if !FileManager.default.fileExists(atPath: Config.shared.path) {
            Config.shared.writeDefault()
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.shared.path))
    }

    @objc func actionReloadConfig() {
        Config.shared.load()
        stopAll()
        startAll()
        log("config: 已重新加载并重启服务")
    }

    @objc func actionOpenSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                values: Config.shared.values(),
                onSave: { [weak self] nv in
                    Config.shared.apply(nv)
                    Config.shared.writeToDisk()
                    self?.stopAll()
                    self?.startAll()
                    log("config: 已通过设置界面保存并应用")
                },
                onReset: { [weak self] in
                    Config.shared.resetToDefaults()
                    Config.shared.writeToDisk()
                    self?.stopAll()
                    self?.startAll()
                    log("config: 已恢复默认配置并应用")
                    return Config.shared.values()
                },
                onClose: { [weak self] in
                    self?.settingsWindow?.close()
                }
            )
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "SplitTunnel 设置"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func actionOpenLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: appLogPath))
    }

    @objc func actionQuit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

// 忽略 SIGPIPE: PAC 客户端断开时 send 不会把整个 App 打崩
signal(SIGPIPE, SIG_IGN)

// SIGTERM 优雅退出 (走 applicationWillTerminate 清理隧道/PAC)
signal(SIGTERM) { _ in
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
