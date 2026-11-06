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
    /// 子进程环境：显式补上 wg / wg-quick 所在目录。
    /// App 从 Finder 启动时 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
    /// 而 wg-quick 的 shebang 是 `#!/usr/bin/env bash`，会解析到系统 bash 3.2 →
    /// 报 "Version mismatch: bash 3 detected, when bash 4+ required"。
    /// 在 Process 上设置 environment 可透传给 sudo 及其子进程（实测有效）。
    static var baseEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // 只在真正存在工具的目录里挑，并保持 Apple Silicon → Intel → MacPorts 的优先顺序
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        parts.removeAll { candidates.contains($0) }        // 先剔除已有的，避免重复
        env["PATH"] = (candidates + parts).joined(separator: ":")
        return env
    }

    /// 同步执行并捕获输出。
    /// 读端在后台线程并发消费：若等进程退出后才读，子进程输出超过管道缓冲
    /// （64KB）就会写阻塞，被误判成执行超时。
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 30,
                    input: String? = nil) -> (rc: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = baseEnvironment
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        if input != nil { p.standardInput = inPipe }

        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setErr(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do { try p.run() } catch { return (126, "", error.localizedDescription) }

        if let input {
            inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(30_000) }
        if p.isRunning {
            // 只 terminate() 会留下孙进程：sudo 被杀掉后 wg-quick / route 会变成孤儿。
            // 先尝试杀整个进程组，再逐个兜底。
            let pgid = getpgid(p.processIdentifier)
            if pgid > 0 { kill(-pgid, SIGTERM) }
            p.terminate()
            let grace = Date().addingTimeInterval(2)
            while p.isRunning && Date() < grace { usleep(20_000) }
            if p.isRunning {
                if pgid > 0 { kill(-pgid, SIGKILL) }
                kill(p.processIdentifier, SIGKILL)
            }
            return (124, "", "执行超时")
        }
        // 进程已退出，读线程随 EOF 收尾
        _ = group.wait(timeout: .now() + 3)
        return (p.terminationStatus, box.outText, box.errText)
    }

    /// 两个读线程共享的结果容器（加锁访问）
    private final class OutputBox {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
        func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
        var outText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
        var errText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
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
    /// PersistentKeepalive 秒数；nil 表示配置里没写该行
    let persistentKeepalive: Int?
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
    /// 依次探测 Homebrew（Apple Silicon / Intel）、MacPorts 与常见路径。
    /// 硬编码单一路径会让另一架构的 Mac 直接不可用。
    static let wgPath: String = findTool("wg")
    static let wgQuickPath: String = findTool("wg-quick")
    static let sudo = "/usr/bin/sudo"

    /// 系统 bash 是 3.2，而 wg-quick 第 42 行硬性要求 bash 4+。
    /// PATH 里补上 Homebrew 目录后，`#!/usr/bin/env bash` 就能解析到 bash 5，
    /// 不需要改动 sudoers，也不需要自己拼 bash 命令。
    /// 这里只保留一个前置校验，好在最坏情况下给出可读的错误。
    static var bashTooOld: Bool {
        let (_, out, _) = Shell.run("/usr/bin/env", ["bash", "-c", "echo ${BASH_VERSINFO[0]}"],
                                    timeout: 5)
        return (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) < 4
    }

    private static func findTool(_ name: String) -> String {
        let candidates = [
            "/opt/homebrew/bin/\(name)",     // Apple Silicon Homebrew
            "/usr/local/bin/\(name)",        // Intel Homebrew
            "/opt/local/bin/\(name)",        // MacPorts
            "/usr/bin/\(name)",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // 都没找到就沿 PATH 再找一次，最后退回 Apple Silicon 默认路径（保持错误信息可读）
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return candidates[0]
    }

    /// 配置目录；单元测试可覆盖此值以隔离真实用户配置
    static var profilesDir: URL = defaultProfilesDir

    private static var defaultProfilesDir: URL {
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

    /// 环境自检：返回 nil 表示一切就绪，否则是可读的问题描述。
    /// 与 sudo 授权分开判断，便于配置页给出针对性提示。
    static func environmentIssue() -> String? {
        if !toolsInstalled {
            return "未找到 wg / wg-quick，请先安装：brew install wireguard-tools"
        }
        if bashTooOld {
            return "wg-quick 需要 bash 4+，但当前 PATH 只能解析到系统 bash 3。"
                 + "请安装 Homebrew bash（brew install bash）后重试。"
        }
        return nil
    }

    /// sudoers 白名单文件路径
    static let sudoersPath = "/etc/sudoers.d/wireguard-gui"

    /// 生成 sudoers 内容：只放行这两个可执行文件，不是全局免密
    static func sudoersContent() -> String {
        let user = NSUserName()
        return "\(user) ALL=(root) NOPASSWD: \(wgQuickPath), \(wgPath)\n"
    }

    /// 一次性授权：通过 osascript 弹系统管理员密码框写入 sudoers。
    /// 走 `do shell script ... with administrator privileges`，密码由系统窗口收集，
    /// App 全程不接触也不存储密码。
    static func installSudoers() -> (ok: Bool, message: String) {
        let content = sudoersContent()
        // 用 sh -c 写入并设权限；路径与内容都来自本程序，不含用户输入
        let script = """
        do shell script "mkdir -p /etc/sudoers.d && printf %s \(shellQuoted(content)) > \(shellQuoted(sudoersPath)) && chmod 440 \(shellQuoted(sudoersPath))" with administrator privileges
        """
        let (rc, out, err) = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        if rc == 0 { return (true, "已授权") }
        let msg = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("-128") || msg.lowercased().contains("cancel") {
            return (false, "已取消授权")
        }
        return (false, msg.isEmpty ? "授权失败" : msg)
    }

    /// 撤销授权
    static func removeSudoers() -> (ok: Bool, message: String) {
        let script = """
        do shell script "rm -f \(shellQuoted(sudoersPath))" with administrator privileges
        """
        let (rc, out, err) = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        if rc == 0 { return (true, "已撤销授权") }
        let msg = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("-128") { return (false, "已取消") }
        return (false, msg.isEmpty ? "撤销失败" : msg)
    }

    /// 把字符串包成 AppleScript 字符串字面量（双引号转义，反斜杠转义）
    private static func shellQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
                let ka = extract(text, "PersistentKeepalive")
                return Profile(
                    name: url.deletingPathExtension().lastPathComponent,
                    address: extract(text, "Address"),
                    endpoint: extract(text, "Endpoint"),
                    dns: extract(text, "DNS"),
                    peerKey: key.isEmpty ? "" : String(key.prefix(16)) + "…",
                    allowedIPs: extract(text, "AllowedIPs"),
                    persistentKeepalive: Int(ka.trimmingCharacters(in: .whitespaces)))
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
        // wg-quick 的键名不区分大小写，这里也用 caseInsensitive
        let re = try? NSRegularExpression(pattern: "^[ \\t]*PrivateKey[ \\t]*=",
                                          options: [.anchorsMatchLines, .caseInsensitive])
        let ns = text as NSString
        if re?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) == nil {
            return "缺少 PrivateKey"
        }
        return nil
    }

    /// 直接落盘（调用方负责校验与重名判断）
    private static func writeProfileRaw(name: String, text: String) throws {
        let url = profileURL(name)
        try (text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func importProfile(_ name: String, _ text: String) throws {
        if let err = validateName(name) { throw WGError.failed(err) }
        if let err = validateConf(text) { throw WGError.failed(err) }
        // 已存在同名配置直接拒绝：否则会静默覆盖旧配置（可能含别的私钥）
        if FileManager.default.fileExists(atPath: profileURL(name).path) {
            throw WGError.failed("已存在名为「\(name)」的配置，请换一个名称")
        }
        try writeProfileRaw(name: name, text: text)
    }

    /// 保存配置；oldName 非空且与新名不同表示改名（会先断开旧接口、写新文件、删旧文件）
    static func saveProfile(name: String, text: String, renamingFrom oldName: String?) throws {
        if let err = validateName(name) { throw WGError.failed(err) }
        if let err = validateConf(text) { throw WGError.failed(err) }

        let isRename = (oldName != nil) && oldName != name

        guard isRename, let old = oldName else {
            // 同名编辑：目标文件本就该被覆盖，但必须确认它确实属于旧配置
            try writeProfileRaw(name: name, text: text)
            return
        }

        // 改名顺序很重要：先查重（失败时不能已经断掉用户的隧道），再断旧接口
        let newURL = profileURL(name)
        if FileManager.default.fileExists(atPath: newURL.path) {
            throw WGError.failed("已存在名为「\(name)」的配置")
        }
        let oldURL = profileURL(old)
        if FileManager.default.fileExists(atPath: oldURL.path) {
            // 只有旧接口确实在运行才需要先 down；不在运行时 wg-quick down 会报
            // "is not a WireGuard interface"，不该因此阻断改名
            if runningProfiles().contains(old) {
                let (rc, out, err) = Shell.run(sudo, ["-n", wgQuickPath, "down", oldURL.path], timeout: 60)
                if rc != 0 {
                    // 接口没断成，绝不能删旧文件，否则留下 App 管不到的孤儿 utun 和丢配置
                    let msg = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw WGError.failed("旧配置「\(old)」断开失败，改名已中止：\n"
                                         + (msg.isEmpty ? "wg-quick down 返回 \(rc)" : msg))
                }
            }
        }
        try writeProfileRaw(name: name, text: text)
        try? FileManager.default.removeItem(at: oldURL)
    }

    static func deleteProfile(_ name: String) throws {
        if let err = validateName(name) { throw WGError.failed(err) }
        let url = profileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WGError.failed("配置不存在")
        }
        // 只有接口确实在运行时才需要先 down（否则 wg-quick 会报 not a WireGuard interface）
        if runningProfiles().contains(name) {
            _ = Shell.run(sudo, ["-n", wgQuickPath, "down", url.path], timeout: 60)
        }
        try FileManager.default.removeItem(at: url)
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
}

// MARK: - 辅助

/// 秒数 → "1分30秒" 这类可读文本（诊断日志用）
func fmtBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
}

extension WG {
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

// MARK: - 出口 IP 探测

/// 握手成功后查询公网出口 IP，让用户能直观确认"流量真的走了隧道"。
/// 只请求纯文本返回的接口，不做 JSON 解析；失败静默（很多内网配置根本不通外网）。
enum EchoIP {
    private static let endpoints = [
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
    ]

    /// 同步查询（调用方应放在后台队列）
    static func query(timeout: TimeInterval = 8) -> String? {
        for urlString in endpoints {
            guard let url = URL(string: urlString) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            req.setValue("WireGuardConsole", forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0)
            var result: String?
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                defer { sem.signal() }
                guard let data,
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { return }
                let ip = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 只接受看起来像 IP 的短字符串，避免把 HTML 错误页当成结果
                if ip.count <= 45, ip.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                   ip.contains(".") || ip.contains(":") {
                    result = ip
                }
            }.resume()
            if sem.wait(timeout: .now() + timeout + 2) == .success, let r = result { return r }
        }
        return nil
    }
}

// MARK: - 失败诊断

/// 把手把 wg-quick 的原始报错翻译成可操作的建议。
/// 参考 Mullvad / Tailscale 的做法：不甩日志，直接说"下一步该查什么"。
enum Diagnose {
    struct Finding {
        let title: String        // 一句话结论
        let advice: [String]     // 可执行的下一步
    }

    static func from(output: String, profile: Profile, peer: PeerStatus?) -> Finding? {
        let low = output.lowercased()

        if low.contains("version mismatch") && low.contains("bash") {
            return Finding(title: "bash 版本过低",
                           advice: ["wg-quick 需要 bash 4+，macOS 自带的是 3.2",
                                    "执行 brew install bash 安装新版",
                                    "装好后重开 App（PATH 需要重新探测）"])
        }
        if low.contains("is not a wireguard interface") {
            return Finding(title: "接口状态不一致",
                           advice: ["可能已由命令行或其他工具断开",
                                    "点一次「断开」清掉残留状态，再重新连接"])
        }
        if low.contains("operation not permitted") || low.contains("permission denied")
            || low.contains("a password is required") || low.contains("no tty present") {
            return Finding(title: "缺少 sudo 授权",
                           advice: ["App 需要免密调用 wg-quick",
                                    "在配置页点「授权」，或按 README 手动写入 sudoers"])
        }
        if low.contains("resolvconf") || low.contains("dns") && low.contains("fail") {
            return Finding(title: "DNS 设置失败",
                           advice: ["macOS 的 wg-quick 处理 DNS 依赖 resolvconf，容易失败",
                                    "若不需要隧道内 DNS，把配置里的 DNS = 行删掉（路由仍生效）"])
        }
        if low.contains("address already in use") || low.contains("already exists") {
            return Finding(title: "接口或地址已被占用",
                           advice: ["同名接口可能还在运行",
                                    "点「断开」后再连；若无效可重启 App"])
        }
        if low.contains("could not resolve") || low.contains("name or service not known")
            || low.contains("nodename nor servname") {
            return Finding(title: "Endpoint 域名解析失败",
                           advice: ["检查 Endpoint 里的域名是否拼写正确",
                                    "确认当前网络能解析该域名（公司内网域名需先连公司网络）"])
        }
        if low.contains("no such file") && low.contains("conf") {
            return Finding(title: "配置文件读不到",
                           advice: ["配置可能已被移动或删除", "重新导入一次配置文件"])
        }

        // 已建接口但零回包：最常见的"端点不可达"
        if let peer, peer.tx > 0, peer.rx == 0 {
            return Finding(
                title: "已发出数据但对端零响应",
                advice: ["确认 \(profile.endpoint) 可达且服务端在监听该 UDP 端口",
                         "检查服务端的 PublicKey 与本地 PrivateKey 是否配对",
                         "若在受限网络，UDP 51820 可能被拦截，尝试换端口或走 TCP 封装"])
        }
        if let peer, peer.tx == 0, peer.rx == 0 {
            return Finding(
                title: "接口已建立但没有任何流量",
                advice: ["AllowedIPs 可能没有覆盖你访问的网段（当前 \(profile.allowedIPs)）",
                         "确认目标地址落在该网段内"])
        }
        return nil
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

    /// 某配置"有 .name 但在 wg 接口列表里查不到"的连续轮询次数，用于识别残留标记文件
    private var missingIfaceRounds: [String: Int] = [:]
    /// 连续多少轮查不到接口就判定为残留（每轮 5 秒）
    private let staleMarkerRounds = 3
    /// 已提示过"无 keepalive 空闲属正常"的配置，避免反复刷日志
    private var keepaliveIdleNoted: Set<String> = []

    /// 握手成功后的公网出口 IP（用于确认流量确实走了隧道）
    private(set) var exitIP: [String: String] = [:]
    /// 出口 IP 探测中，避免重复请求
    private var exitIPInFlight: Set<String> = []

    /// 唤醒后待重连的配置（睡眠会让隧道静默失效）
    private var pendingReconnect: Set<String> = []

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
        let busySnapshot = busy
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
                // 查询期间可能新发起了操作：对这批配置不要用旧快照推进状态机，
                // 否则会把 .connecting 错判成"接口已不存在"
                if self.busy.isSubset(of: busySnapshot) {
                    self.advancePhases(act)
                }
                self.updateSpeeds(act)
                self.notify()
            }
        }
    }

    // MARK: 操作（带握手判定）

    /// 每次发起连接递增；取消时递增即可让在途的 up 结果失效
    private var connectGeneration: [String: Int] = [:]

    func connect(_ name: String) {
        guard !busy.contains(name) else {
            appendLog(name, "上一步操作还在进行，请稍候再试", .warn)
            return
        }
        busy.insert(name)
        phases[name] = .connecting
        connectStartedAt[name] = Date()
        let gen = (connectGeneration[name] ?? 0) + 1
        connectGeneration[name] = gen
        appendLog(name, "开始连接 …", .info)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let output = try WG.connect(name)
                DispatchQueue.main.async {
                    // 期间被取消：丢弃这次结果，但必须释放 busy
                    guard self.connectGeneration[name] == gen else {
                        self.busy.remove(name)
                        self.refresh()
                        return
                    }
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
                    guard self.connectGeneration[name] == gen else {
                        self.busy.remove(name)
                        self.refresh()
                        return
                    }
                    let msg = error.localizedDescription
                    for line in msg.split(separator: "\n") where !line.isEmpty {
                        self.appendLog(name, String(line), .error)
                    }
                    self.appendLog(name, "连接失败，请查看上方错误输出", .error)
                    self.phases[name] = .failed(reason: "wg-quick up 失败")
                    self.busy.remove(name)
                    // 把原始报错翻译成可操作的结论
                    if let p = self.profiles.first(where: { $0.name == name }) {
                        let peer = self.status(for: name)?.peers.first
                        if let d = Diagnose.from(output: msg, profile: p, peer: peer) {
                            self.lastDiagnosis[name] = d
                            self.appendLog(name, "诊断 · \(d.title)", .warn)
                            for a in d.advice { self.appendLog(name, "  → \(a)", .warn) }
                        }
                    }
                    self.onError?(name, msg)
                    self.refresh()
                }
            }
        }
    }

    /// 中止正在进行的 wg-quick up。
    /// 进程本身在后台线程里同步跑着、无法直接杀掉，这里让它的结果作废，
    /// 再在旁边发一次 down 把可能已建好的接口清掉。
    func cancelConnect(_ name: String) {
        guard busy.contains(name), phases[name] == .connecting else { return }
        connectGeneration[name] = (connectGeneration[name] ?? 0) + 1
        connectStartedAt[name] = nil
        phases[name] = .disconnected
        appendLog(name, "已取消连接", .warn)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? WG.disconnect(name)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func disconnect(_ name: String) {
        guard !busy.contains(name) else {
            appendLog(name, "上一步操作还在进行，请稍候再试", .warn)
            return
        }
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
                    self.exitIP[name] = nil
                    self.lastDiagnosis[name] = nil
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
        guard !busy.contains(name) else {
            appendLog(name, "该配置正在连接/断开，等操作完成后再删除", .warn)
            onError?("暂时无法删除", "配置「\(name)」正在执行连接或断开操作，请等它完成后再删除。")
            return
        }
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
        // 通知 UI：满 300 条后 count 恒定，界面必须靠这个信号刷新
        logRevision[name, default: 0] += 1
    }

    /// 每个配置的日志版本号（append/clear 时递增）。
    /// 日志有 300 条上限，长度会饱和，因此不能靠 count 判断是否需要重绘。
    private(set) var logRevision: [String: Int] = [:]

    func logLines(for name: String) -> [LogLine] { logs[name] ?? [] }

    func clearLogs(for name: String) {
        logs[name] = []
        logRevision[name, default: 0] += 1
    }

    func phase(for name: String) -> ConnectPhase { phases[name] ?? .disconnected }

    /// 最近一次失败的诊断结论（首页/配置页可直接展示可操作建议）
    private(set) var lastDiagnosis: [String: Diagnose.Finding] = [:]

    /// 握手成功后异步查一次公网出口 IP，用于确认流量确实走了隧道
    private func refreshExitIP(_ name: String) {
        guard exitIP[name] == nil, !exitIPInFlight.contains(name) else { return }
        exitIPInFlight.insert(name)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ip = EchoIP.query()
            DispatchQueue.main.async {
                guard let self else { return }
                self.exitIPInFlight.remove(name)
                guard let ip else { return }
                self.exitIP[name] = ip
                self.appendLog(name, "出口 IP：\(ip)", .info)
                self.notify()
            }
        }
    }

    /// 睡眠唤醒 / 网络切换后调用：已连接的配置主动断开重连，
    /// 因为 macOS 上睡眠会让隧道静默失效而 App 不一定感知到。
    func handleWake() {
        // 网络切换会在短时间内触发多次，加防抖避免反复重连把隧道打断
        if let last = lastWakeHandled, Date().timeIntervalSince(last) < 20 { return }
        let live = running.filter { (phases[$0] ?? .disconnected) == .connected }
        guard !live.isEmpty else { return }
        lastWakeHandled = Date()
        for name in live {
            guard !busy.contains(name) else { continue }
            appendLog(name, "检测到系统唤醒或网络切换，重新建立隧道 …", .info)
            pendingReconnect.insert(name)
            busy.insert(name)
            // 先断开再连，避免旧 utun 上的路由残留
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = try? WG.disconnect(name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy.remove(name)
                    self.connect(name)
                }
            }
        }
    }

    /// 上次处理唤醒重连的时刻（用于防抖）
    private var lastWakeHandled: Date?


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
            exitIP[key] = nil
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
            // 正在执行操作的不推进（避免用旧快照覆盖刚设置的状态）
            guard !busy.contains(name) else { continue }

            guard running.contains(name) else {
                missingIfaceRounds[name] = nil
                // 外部把接口关了
                if phase.isUp {
                    phases[name] = .disconnected
                    appendLog(name, "接口已不存在，状态回到未连接", .warn)
                    connectStartedAt[name] = nil
                }
                continue
            }

            // 有 .name 标记但拿不到接口数据：可能是 wg-quick 异常退出留下的残留标记，
            // 也可能是接口刚建立还没就绪。连续多轮都查不到才降级为未连接。
            guard let st = status(for: name), let peer = st.peers.first else {
                let rounds = (missingIfaceRounds[name] ?? 0) + 1
                missingIfaceRounds[name] = rounds
                if rounds >= staleMarkerRounds, phase.isUp {
                    phases[name] = .failed(reason: "接口数据不可读（可能是残留的运行标记）")
                    appendLog(name, "连续 \(rounds) 次读不到接口信息，判定为残留运行标记；"
                                    + "可尝试断开后重新连接", .warn)
                    connectStartedAt[name] = nil
                    connectedSince[name] = nil
                }
                continue
            }
            missingIfaceRounds[name] = nil

            let hs = peer.latestHandshake
            let fresh = hs.map { Date().timeIntervalSince($0) < 180 } ?? false
            // 无 PersistentKeepalive 的空闲隧道不会定时重新握手，握手看起来"过期"属正常，
            // 此时不应判成失败
            let keepaliveIdle = profile.persistentKeepalive == nil

            switch phase {
            case .connecting:
                break
            case .awaitingHandshake, .failed:
                if fresh {
                    phases[name] = .connected
                    appendLog(name, "握手成功，隧道已连通", .success)
                    connectStartedAt[name] = nil
                    if connectedSince[name] == nil { connectedSince[name] = Date() }
                    refreshExitIP(name)
                } else if phase == .awaitingHandshake {
                    // 超时判定
                    if let t0 = connectStartedAt[name],
                       Date().timeIntervalSince(t0) > handshakeTimeout {
                        phases[name] = .failed(reason: "等待握手超时（\(Int(handshakeTimeout)) 秒内未收到对端响应）")
                        appendLog(name, "握手超时：对端 \(profile.endpoint) 无响应，已自动断开", .error)
                        // 用诊断模块给出可操作的下一步，而不是只丢一句"对方无响应"
                        if let d = Diagnose.from(output: "", profile: profile, peer: peer) {
                            appendLog(name, "诊断 · \(d.title)", .warn)
                            for a in d.advice { appendLog(name, "  → \(a)", .warn) }
                        }
                        lastDiagnosis[name] = Diagnose.from(output: "", profile: profile, peer: peer)
                        autoDisconnect(name)
                    }
                }
            case .connected:
                if !fresh, hs != nil, !keepaliveIdle {
                    phases[name] = .failed(reason: "握手已过期（超过 3 分钟无新握手）")
                    appendLog(name, "握手已过期，隧道可能已失效", .warn)
                } else if !fresh, hs != nil, keepaliveIdle {
                    // 空闲隧道：保留已连接状态，仅在日志里提示一次
                    if !keepaliveIdleNoted.contains(name) {
                        keepaliveIdleNoted.insert(name)
                        appendLog(name, "握手时间较久：该配置无 PersistentKeepalive，空闲时不会重新握手，属正常现象", .info)
                    }
                } else if hs == nil {
                    phases[name] = .awaitingHandshake
                }
            case .disconnected:
                if fresh {
                    phases[name] = .connected
                    appendLog(name, "检测到已有握手，状态同步为已连接", .info)
                    // 外部（命令行）建立的隧道也要能显示连接时长
                    if connectedSince[name] == nil { connectedSince[name] = hs ?? Date() }
                }
            }
        }
    }

    /// 握手超时自动断开，避免"假连接"
    private func autoDisconnect(_ name: String) {
        guard !busy.contains(name) else { return }
        connectStartedAt[name] = nil
        // 占用 busy：否则用户在这段时间点「连接」会和后台的 down 交错，
        // 可能把刚要建立的隧道拆掉
        busy.insert(name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? WG.disconnect(name)
            DispatchQueue.main.async {
                guard let self else { return }
                self.appendLog(name, "已自动断开，避免处于假连接状态", .warn)
                self.busy.remove(name)
                self.refresh()
            }
        }
    }

    private func notify() {
        onChange?()
    }
}
