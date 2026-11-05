// WGCore.swift — WireGuard 逻辑层
// 从 server.py 移植：配置管理 + wg/wg-quick 调用 + 状态解析，无第三方依赖。
import Foundation

// MARK: - 错误

enum WGError: LocalizedError {
    case toolMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "未找到 wg / wg-quick，请先安装：brew install wireguard-tools"
        case .failed(let msg):
            return msg
        }
    }
}

// MARK: - Shell 执行

enum Shell {
    /// 同步执行并捕获输出；wg 输出都很小，读端缓冲不会死锁
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 30,
                    input: String? = nil) -> (rc: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return (126, "", error.localizedDescription) }

        if let input {
            inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(30_000) }
        if p.isRunning { p.terminate(); return (124, "", "执行超时") }
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out, err)
    }
}

// MARK: - 数据模型

struct Profile: Identifiable, Equatable {
    let name: String
    let address: String
    let endpoint: String
    let dns: String
    let peerKey: String
    let allowedIPs: String
    var id: String { name }

    /// 是否会把全部流量导入隧道（如 0.0.0.0/0、::/0、或掩码为 /0 的写法）。
    /// 这类配置在端点不可达时会让整机断网，连接前应提示。
    var isFullTunnel: Bool {
        allowedIPs.split(separator: ",").contains { item in
            let s = item.trimmingCharacters(in: .whitespaces)
            return s.hasSuffix("/0")
        }
    }
}

struct PeerStatus: Equatable {
    var endpoint = ""
    var allowedIPs = ""
    var latestHandshake: Date?
    var rx = 0
    var tx = 0
}

struct IfaceStatus: Equatable {
    var address = ""
    var peers: [PeerStatus] = []
}

/// 连接阶段：只有握手成功才算真正连上
enum ConnectPhase: Equatable {
    case disconnected
    case connecting          // wg-quick up 正在执行
    case awaitingHandshake   // 接口已建，等握手（超时会判失败）
    case connected           // 握手成功且在有效期内
    case failed(reason: String)   // 超时未握手 / 命令失败

    var isUp: Bool {
        switch self {
        case .connecting, .awaitingHandshake, .connected: return true
        case .disconnected, .failed: return false
        }
    }
}

/// 一条日志
struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let time = Date()
    let text: String
    let level: Level
    enum Level { case info, warn, error, success }
}

// MARK: - 核心操作

enum WG {
    static let wgPath = "/opt/homebrew/bin/wg"
    static let wgQuickPath = "/opt/homebrew/bin/wg-quick"
    static let sudo = "/usr/bin/sudo"

    static var profilesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WireGuardConsole/profiles", isDirectory: true)
    }

    static func ensureDirs() {
        try? FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    }

    static var toolsInstalled: Bool {
        FileManager.default.fileExists(atPath: wgPath)
            && FileManager.default.fileExists(atPath: wgQuickPath)
    }

    static func sudoReady() -> Bool {
        Shell.run(sudo, ["-n", "-l", wgQuickPath]).rc == 0
    }

    // MARK: 配置文件

    static func listProfiles() -> [Profile] {
        ensureDirs()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: profilesDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "conf" }
            .compactMap { url -> Profile? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let key = extract(text, "PublicKey")
                return Profile(
                    name: url.deletingPathExtension().lastPathComponent,
                    address: extract(text, "Address"),
                    endpoint: extract(text, "Endpoint"),
                    dns: extract(text, "DNS"),
                    peerKey: key.isEmpty ? "" : String(key.prefix(16)) + "…",
                    allowedIPs: extract(text, "AllowedIPs"))
            }
            .sorted { $0.name < $1.name }
    }

    static func profileURL(_ name: String) -> URL {
        profilesDir.appendingPathComponent(name + ".conf")
    }

    /// 配置名 = 接口名，必须符合 wg-quick 的硬性要求：
    /// `[a-zA-Z0-9_=+.-]{1,15}`（不足 16 字符，且只能是 ASCII）
    /// 中文/空格/其他符号会被 wg-quick 直接拒绝。
    static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "配置名称不能为空" }
        let pattern = "^[a-zA-Z0-9_=+.-]{1,15}$"
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            if name.count > 15 {
                return "名称不能超过 15 个字符（wg-quick 的接口名限制）"
            }
            return "名称只能包含英文字母、数字和 _ = + . -（不支持中文，因为要作为网络接口名）"
        }
        guard !name.hasPrefix(".") else {
            return "名称不能以 . 开头"
        }
        return nil
    }

    static func validateConf(_ text: String) -> String? {
        if !text.lowercased().contains("[interface]") { return "缺少 [interface] 段" }
        let re = try? NSRegularExpression(pattern: "^[ \\t]*PrivateKey[ \\t]*=",
                                          options: [.anchorsMatchLines])
        let ns = text as NSString
        if re?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) == nil {
            return "缺少 PrivateKey"
        }
        return nil
    }

    static func importProfile(_ name: String, _ text: String) throws {
        if let err = validateName(name) { throw WGError.failed(err) }
        if let err = validateConf(text) { throw WGError.failed(err) }
        let url = profileURL(name)
        try (text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 保存配置；oldName 非空且与新名不同表示改名（会先断开旧接口、写新文件、删旧文件）
    static func saveProfile(name: String, text: String, renamingFrom oldName: String?) throws {
        if let err = validateName(name) { throw WGError.failed(err) }
        if let err = validateConf(text) { throw WGError.failed(err) }

        let isRename = (oldName != nil) && oldName != name

        if isRename, let old = oldName {
            let oldURL = profileURL(old)
            // 旧配置在运行时先断开，否则接口名与新文件名错位
            if FileManager.default.fileExists(atPath: oldURL.path) {
                _ = Shell.run(sudo, ["-n", wgQuickPath, "down", oldURL.path], timeout: 60)
            }
            // 新名已存在则拒绝，避免覆盖别的配置
            let newURL = profileURL(name)
            if FileManager.default.fileExists(atPath: newURL.path) {
                throw WGError.failed("已存在名为「\(name)」的配置")
            }
            try (text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
                .write(to: newURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: newURL.path)
            try? FileManager.default.removeItem(at: oldURL)
        } else {
            try importProfile(name, text)
        }
    }

    static func deleteProfile(_ name: String) throws {
        if let err = validateName(name) { throw WGError.failed(err) }
        let url = profileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WGError.failed("配置不存在")
        }
        let (rc, _, _) = Shell.run(sudo, ["-n", wgQuickPath, "down", url.path], timeout: 60)
        try FileManager.default.removeItem(at: url)
        if rc != 0 { /* 接口本就不在等情况，忽略 */ }
    }

    // MARK: 连接 / 断开

    static func connect(_ name: String) throws -> String {
        let url = profileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WGError.failed("配置不存在")
        }
        let (rc, out, err) = Shell.run(sudo, ["-n", wgQuickPath, "up", url.path], timeout: 60)
        let msg = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if rc != 0 { throw WGError.failed(String(msg.suffix(2000))) }
        return msg
    }

    static func disconnect(_ name: String) throws -> String {
        let url = profileURL(name)
        let (rc, out, err) = Shell.run(sudo, ["-n", wgQuickPath, "down", url.path], timeout: 60)
        let msg = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if rc != 0 { throw WGError.failed(String(msg.suffix(2000))) }
        return msg
    }

    // MARK: 状态

    /// 当前有活动接口的配置名集合。
    /// wg-quick 在 up 时创建 /var/run/wireguard/<配置名>.name，down 时删除，
    /// 这是判断"某个配置是否在运行"的权威来源（接口名是 utunX，无法从配置名推）。
    static func runningProfiles() -> Set<String> {
        let dir = "/var/run/wireguard"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return Set(files.filter { $0.hasSuffix(".name") }.map { String($0.dropLast(5)) })
    }

    /// 列出当前运行的 WireGuard 接口（macOS 上是 utunX）。
    /// 注意：macOS 的 wg 不支持不带接口名的 `wg show dump`，必须逐接口查询。
    static func interfaces() -> [String] {
        let (rc, out, _) = Shell.run(sudo, ["-n", wgPath, "show", "interfaces"], timeout: 10)
        guard rc == 0 else { return [] }
        return out.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 读取接口的 IPv4 地址（用于把 utunX 映射回配置）
    static func address(of iface: String) -> String {
        let (rc, out, _) = Shell.run("/sbin/ifconfig", [iface], timeout: 10)
        guard rc == 0 else { return "" }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("inet ") {
                let parts = t.split(separator: " ").map(String.init)
                if parts.count >= 2 { return parts[1] }
            }
        }
        return ""
    }

    /// 解析所有运行中的接口状态：[接口名: 状态]
    static func status() -> [String: IfaceStatus] {
        var result: [String: IfaceStatus] = [:]
        for iface in interfaces() {
            var st = IfaceStatus()
            st.address = address(of: iface)
            let (_, out, _) = Shell.run(sudo, ["-n", wgPath, "show", iface, "dump"], timeout: 10)
            for (idx, line) in out.split(separator: "\n").enumerated() {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                // 首行是接口行（private public listen-port fwmark），跳过
                if idx == 0 { continue }
                // peer 行 8 列: public-key preshared endpoint allowed-ips
                //               latest-handshake rx tx persistent-keepalive
                if f.count >= 8 {
                    let hs = TimeInterval(f[4]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                    st.peers.append(PeerStatus(
                        endpoint: f[2],
                        allowedIPs: f[3],
                        latestHandshake: hs,
                        rx: Int(f[5]) ?? 0,
                        tx: Int(f[6]) ?? 0))
                }
            }
            result[iface] = st
        }
        return result
    }

    // MARK: 密钥

    static func genKeys() throws -> (priv: String, pub: String, psk: String) {
        let g = Shell.run(wgPath, ["genkey"])
        guard g.rc == 0 else { throw WGError.failed("wg genkey 失败") }
        let priv = g.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Shell.run(wgPath, ["pubkey"], input: priv + "\n")
        guard p.rc == 0 else { throw WGError.failed("wg pubkey 失败") }
        let psk = Shell.run(wgPath, ["genpsk"])
        return (priv, p.out.trimmingCharacters(in: .whitespacesAndNewlines),
                psk.rc == 0 ? psk.out.trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    // MARK: 辅助

    private static func extract(_ text: String, _ key: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "^[ \\t]*\(key)[ \\t]*=[ \\t]*(.+?)[ \\t]*$",
            options: [.anchorsMatchLines, .caseInsensitive]) else { return "" }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return "" }
        return ns.substring(with: m.range(at: 1))
    }
}

// MARK: - 状态仓库（纯 AppKit 环境，无 Combine 依赖）

final class ProfileStore {
    private(set) var profiles: [Profile] = []
    private(set) var active: [String: IfaceStatus] = [:]
    private(set) var running: Set<String> = []
    private(set) var sudoReady = true
    private(set) var busy: Set<String> = []

    /// 实时速率（下载/上传，字节每秒）与上次采样
    private(set) var speeds: [String: (down: Double, up: Double)] = [:]
    private var lastSample: [String: (rx: Int, tx: Int, at: Date)] = [:]
    /// 连接成功时刻（用于显示连接时长）
    private(set) var connectedSince: [String: Date] = [:]

    /// 每个配置的连接阶段与最近一次操作的日志
    private(set) var phases: [String: ConnectPhase] = [:]
    private(set) var logs: [String: [LogLine]] = [:]
    /// 连接发起时刻，用于握手超时判定
    private var connectStartedAt: [String: Date] = [:]
    /// 握手超时秒数：超过仍未握手则判定失败并自动断开
    var handshakeTimeout: TimeInterval = 12

    /// 状态变化回调（主线程）
    var onChange: (() -> Void)?
    /// 操作失败回调（主线程：标题, 输出）
    var onError: ((_ title: String, _ message: String) -> Void)?

    private var timer: Timer?
    private var refreshing = false

    init() {
        WG.ensureDirs()
    }

    /// 该配置对应的运行中接口状态（配置是否运行以 wg-quick 的 .name 标记为准，
    /// 接口状态按接口 IP 与配置 Address 匹配）
    func status(for name: String) -> IfaceStatus? {
        guard running.contains(name) else { return nil }
        guard let profile = profiles.first(where: { $0.name == name }) else { return nil }
        let addr = profile.address.split(separator: "/").first.map(String.init) ?? ""
        let match = active.first(where: { $0.value.address == addr })?.value
        return match ?? active.values.first
    }

    func isActive(_ name: String) -> Bool { running.contains(name) }

    var activeCount: Int { running.count }

    func startPolling(every interval: TimeInterval = 5) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        guard !refreshing else { return }
        // 有操作在执行时跳过本轮轮询：wg-quick up/down 期间读状态既慢又会
        // 把 busy 状态覆盖成假"空闲"，用户会觉得点击没反应
        guard busy.isEmpty else { return }
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // 串行但对每个 sudo 调用做短路：无隧道时只剩 1 次 sudo 往返
            let run = WG.runningProfiles()
            let sudo = WG.sudoReady()
            let list = WG.listProfiles()
            let act = run.isEmpty ? [:] : WG.status()
            DispatchQueue.main.async {
                self.refreshing = false
                self.sudoReady = sudo
                self.profiles = list
                self.active = act
                self.running = run
                self.advancePhases(act)
                self.updateSpeeds(act)
                self.notify()
            }
        }
    }

    // MARK: 操作（带握手判定）

    func connect(_ name: String) {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        phases[name] = .connecting
        connectStartedAt[name] = Date()
        appendLog(name, "开始连接 …", .info)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let output = try WG.connect(name)
                DispatchQueue.main.async {
                    for line in output.split(separator: "\n") where !line.isEmpty {
                        self.appendLog(name, String(line), .info)
                    }
                    self.appendLog(name, "接口已建立，等待握手 …", .info)
                    self.phases[name] = .awaitingHandshake
                    self.busy.remove(name)
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    let msg = error.localizedDescription
                    for line in msg.split(separator: "\n") where !line.isEmpty {
                        self.appendLog(name, String(line), .error)
                    }
                    self.appendLog(name, "连接失败，请查看上方错误输出", .error)
                    self.phases[name] = .failed(reason: "wg-quick up 失败")
                    self.busy.remove(name)
                    self.onError?(name, msg)
                    self.refresh()
                }
            }
        }
    }

    func disconnect(_ name: String) {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        appendLog(name, "开始断开 …", .info)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let output = try WG.disconnect(name)
                DispatchQueue.main.async {
                    for line in output.split(separator: "\n") where !line.isEmpty {
                        self.appendLog(name, String(line), .info)
                    }
                    self.appendLog(name, "已断开", .success)
                    self.phases[name] = .disconnected
                    self.connectStartedAt[name] = nil
                    self.connectedSince[name] = nil
                    self.busy.remove(name)
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendLog(name, error.localizedDescription, .error)
                    self.busy.remove(name)
                    self.onError?(name, error.localizedDescription)
                    self.refresh()
                }
            }
        }
    }

    func delete(_ name: String) {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try WG.deleteProfile(name)
                DispatchQueue.main.async {
                    self.logs[name] = nil
                    self.phases[name] = nil
                    self.connectStartedAt[name] = nil
                    self.busy.remove(name)
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendLog(name, error.localizedDescription, .error)
                    self.busy.remove(name)
                    self.onError?(name, error.localizedDescription)
                    self.refresh()
                }
            }
        }
    }

    // MARK: 日志

    func appendLog(_ name: String, _ text: String, _ level: LogLine.Level) {
        var list = logs[name] ?? []
        list.append(LogLine(text: text, level: level))
        if list.count > 300 { list.removeFirst(list.count - 300) }
        logs[name] = list
    }

    func logLines(for name: String) -> [LogLine] { logs[name] ?? [] }

    func clearLogs(for name: String) { logs[name] = [] }

    func phase(for name: String) -> ConnectPhase { phases[name] ?? .disconnected }

    /// 用两次采样的差值算实时速率
    private func updateSpeeds(_ statuses: [String: IfaceStatus]) {
        let now = Date()
        for name in running {
            guard let peer = status(for: name)?.peers.first else { continue }
            if let last = lastSample[name] {
                let dt = max(now.timeIntervalSince(last.at), 0.5)
                let down = Double(max(peer.rx - last.rx, 0)) / dt
                let up = Double(max(peer.tx - last.tx, 0)) / dt
                speeds[name] = (down, up)
            }
            lastSample[name] = (peer.rx, peer.tx, now)
        }
        for key in lastSample.keys where !running.contains(key) {
            lastSample[key] = nil
            speeds[key] = nil
            connectedSince[key] = nil
        }
    }

    func speed(for name: String) -> (down: Double, up: Double) {
        speeds[name] ?? (0, 0)
    }

    func connectedDuration(for name: String) -> TimeInterval? {
        guard let t = connectedSince[name] else { return nil }
        return Date().timeIntervalSince(t)
    }

    /// 根据真实握手数据推进每个配置的连接阶段；超时未握手则判失败并自动断开
    private func advancePhases(_ statuses: [String: IfaceStatus]) {
        for profile in profiles {
            let name = profile.name
            let phase = phases[name] ?? .disconnected

            guard running.contains(name) else {
                // 外部把接口关了
                if phase.isUp {
                    phases[name] = .disconnected
                    appendLog(name, "接口已不存在，状态回到未连接", .warn)
                    connectStartedAt[name] = nil
                }
                continue
            }

            guard let st = status(for: name), let peer = st.peers.first else { continue }
            let hs = peer.latestHandshake
            let fresh = hs.map { Date().timeIntervalSince($0) < 180 } ?? false

            switch phase {
            case .connecting:
                break
            case .awaitingHandshake, .failed:
                if fresh {
                    phases[name] = .connected
                    appendLog(name, "握手成功，隧道已连通", .success)
                    connectStartedAt[name] = nil
                    if connectedSince[name] == nil { connectedSince[name] = Date() }
                } else if phase == .awaitingHandshake {
                    // 超时判定
                    if let t0 = connectStartedAt[name],
                       Date().timeIntervalSince(t0) > handshakeTimeout {
                        phases[name] = .failed(reason: "等待握手超时（\(Int(handshakeTimeout)) 秒内未收到对端响应）")
                        appendLog(name, "握手超时：对端 \(profile.endpoint) 无响应，已自动断开", .error)
                        if peer.tx > 0 && peer.rx == 0 {
                            appendLog(name, "诊断：已发出 \(fmtBytes(peer.tx)) 但收到 0 字节 —— 对端不可达或未在监听", .warn)
                        }
                        autoDisconnect(name)
                    }
                }
            case .connected:
                if !fresh, hs != nil {
                    phases[name] = .failed(reason: "握手已过期（超过 3 分钟无新握手）")
                    appendLog(name, "握手已过期，隧道可能已失效", .warn)
                } else if hs == nil {
                    phases[name] = .awaitingHandshake
                }
            case .disconnected:
                if fresh {
                    phases[name] = .connected
                    appendLog(name, "检测到已有握手，状态同步为已连接", .info)
                }
            }
        }
    }

    /// 握手超时自动断开，避免"假连接"
    private func autoDisconnect(_ name: String) {
        connectStartedAt[name] = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? WG.disconnect(name)
            DispatchQueue.main.async {
                self?.appendLog(name, "已自动断开，避免处于假连接状态", .warn)
                self?.refresh()
            }
        }
    }

    private func notify() {
        onChange?()
    }
}
