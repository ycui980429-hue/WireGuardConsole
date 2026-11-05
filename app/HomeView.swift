// HomeView.swift — 卡片式单页主界面（按参考图重做）
import AppKit

// MARK: - 配色
enum Theme {
    // 浅色主题：白色卡片 + 浅灰底，参考 iOS/macOS 设置页
    static let bg = NSColor(red: 0.937, green: 0.945, blue: 0.953, alpha: 1)        // #eff1f3 页面底
    static let card = NSColor.white                                                  // #ffffff 卡片
    static let cardBorder = NSColor(red: 0.878, green: 0.890, blue: 0.902, alpha: 1) // #e0e3e6 描边
    static let text = NSColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1)         // #1c2129 主文字
    static let muted = NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)        // #6b7380 次要
    static let faint = NSColor(red: 0.60, green: 0.63, blue: 0.67, alpha: 1)        // #99a1ab 弱化
    static let accent = NSColor(red: 0.20, green: 0.47, blue: 0.90, alpha: 1)       // #3378e6 主色蓝
    static let green = NSColor(red: 0.13, green: 0.65, blue: 0.34, alpha: 1)        // #22a657
    static let orange = NSColor(red: 0.90, green: 0.55, blue: 0.05, alpha: 1)       // #e68c0d
    static let red = NSColor(red: 0.83, green: 0.24, blue: 0.20, alpha: 1)          // #d43d33
    // 浅色下按钮内圆用略深的灰，形成层次
    static let buttonSurface = NSColor(red: 0.975, green: 0.980, blue: 0.984, alpha: 1) // #f9fafb
}

// MARK: - 首页
final class HomeViewController: NSViewController {
    private let store: ProfileStore
    private(set) var currentProfile: String?

    // 控件
    private let scroll = NSScrollView()
    private let contentStack = NSStackView()
    private let powerBtn = PowerButton()
    private let statusTitle = label("未连接", size: 12, weight: .semibold, color: Theme.text)
    private let statusSub = label("点击下方按钮启动隧道", size: 12, color: Theme.muted)
    private var downValue = label("0 B/s", size: 12, weight: .semibold, color: Theme.text)
    private var upValue = label("0 B/s", size: 12, weight: .semibold, color: Theme.text)
    private var nodeNameLabel: NSTextField = {
        let l = label("—", size: 12, weight: .medium, color: Theme.text)
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()
    private var nodeAddrLabel: NSTextField = {
        let l = label("", size: 11.5, color: Theme.muted)
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()
    private var nodeDot: StatusDotView?
    private var handshakeValue = label("—", size: 12, weight: .medium, color: Theme.text)
    private var durationValue = label("—", size: 12, weight: .medium, color: Theme.text)
    private var nodeCard: CardView?
    private var nodeMenuButton: NSButton?

    var onShowLogs: (() -> Void)?
    var onShowConfig: (() -> Void)?

    init(store: ProfileStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg.cgColor
        view = root
        buildLayout()
    }

    private func buildLayout() {
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 18
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 28, bottom: 20, right: 28)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // ① 顶部品牌栏：圆形图标 + 标题
        contentStack.addArrangedSubview(makeBrandBar())
        contentStack.setCustomSpacing(22, after: contentStack.arrangedSubviews.last!)

        // ② 大圆按钮
        powerBtn.translatesAutoresizingMaskIntoConstraints = false
        powerBtn.widthAnchor.constraint(equalToConstant: 176).isActive = true
        powerBtn.heightAnchor.constraint(equalToConstant: 176).isActive = true
        powerBtn.onTap = { [weak self] in self?.toggleConnect() }
        contentStack.addArrangedSubview(powerBtn)

        // ③ 状态文字
        contentStack.addArrangedSubview(statusTitle)
        contentStack.addArrangedSubview(statusSub)
        contentStack.setCustomSpacing(4, after: statusTitle)

        // ④ 速率卡（下载 / 上传）
        contentStack.addArrangedSubview(makeSpeedCard())

        // ⑤ 节点卡
        contentStack.addArrangedSubview(makeNodeCard())

        // ⑥ 握手 / 时长卡
        contentStack.addArrangedSubview(makeStatCard())

        scroll.documentView = contentStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    // MARK: 顶部品牌栏
    private func makeBrandBar() -> NSView {
        let iconBox = NSView()
        iconBox.wantsLayer = true
        iconBox.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
        iconBox.layer?.cornerRadius = 18
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.widthAnchor.constraint(equalToConstant: 36).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)
        icon.contentTintColor = Theme.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])

        let title = label("WireGuard", size: 12, weight: .semibold, color: Theme.text)

        let row = NSStackView(views: [iconBox, title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    // MARK: 速率卡
    private func makeSpeedCard() -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 92).isActive = true
        card.widthAnchor.constraint(equalToConstant: 344).isActive = true

        let downTitle = label("下载", size: 12, color: Theme.faint)
        let upTitle = label("上传", size: 12, color: Theme.faint)
        downValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        upValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

        let downCol = NSStackView(views: [downTitle, downValue])
        downCol.orientation = .vertical
        downCol.alignment = .centerX
        downCol.spacing = 6

        let upCol = NSStackView(views: [upTitle, upValue])
        upCol.orientation = .vertical
        upCol.alignment = .centerX
        upCol.spacing = 6

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 40).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let row = NSStackView(views: [downCol, divider, upCol])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .centerY
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    // MARK: 节点卡
    private func makeNodeCard() -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 64).isActive = true
        card.widthAnchor.constraint(equalToConstant: 344).isActive = true
        nodeCard = card

        let dot = StatusDotView(live: false)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        nodeDot = dot

        let col = NSStackView(views: [nodeNameLabel, nodeAddrLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2

        // 真实箭头：手绘（箭杆 + 箭头），清晰可辨
        let arrow = ArrowButton(target: self, action: #selector(showNodeMenu(_:)))
        arrowRef = arrow
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.widthAnchor.constraint(equalToConstant: 24).isActive = true
        arrow.heightAnchor.constraint(equalToConstant: 24).isActive = true
        arrow.toolTip = "切换节点"
        nodeMenuButton = arrow

        let row = NSStackView(views: [dot, col, NSView(), arrow])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        nodeCardRef = card
        // 整卡可点击切换节点
        let click = NSClickGestureRecognizer(target: self, action: #selector(cardTapped(_:)))
        card.addGestureRecognizer(click)
        return card
    }

    @objc private func cardTapped(_ sender: NSClickGestureRecognizer) {
        guard let btn = nodeMenuButton else { return }
        showNodeMenu(btn)
    }

    // MARK: 握手 / 时长卡
    private func makeStatCard() -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 64).isActive = true
        card.widthAnchor.constraint(equalToConstant: 344).isActive = true

        let hsTitle = label("最近握手", size: 12, color: Theme.faint)
        let durTitle = label("连接时长", size: 12, color: Theme.faint)
        handshakeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        durationValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let hsCol = NSStackView(views: [hsTitle, handshakeValue])
        hsCol.orientation = .vertical
        hsCol.alignment = .centerX
        hsCol.spacing = 5

        let durCol = NSStackView(views: [durTitle, durationValue])
        durCol.orientation = .vertical
        durCol.alignment = .centerX
        durCol.spacing = 5

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 34).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let row = NSStackView(views: [hsCol, divider, durCol])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .centerY
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    // MARK: 数据刷新
    func update(profileName: String?) {
        currentProfile = profileName ?? store.profiles.first?.name
        guard let name = currentProfile,
              let profile = store.profiles.first(where: { $0.name == name }) else {
            statusTitle.stringValue = "未连接"
            statusSub.stringValue = "还没有配置，去添加一个吧"
            powerBtn.mode = .disconnected
            // 节点卡显示引导文案（与下拉里的提示一致）
            nodeNameLabel.stringValue = "暂无配置"
            nodeNameLabel.textColor = Theme.faint
            nodeAddrLabel.stringValue = "点击添加配置"
            nodeAddrLabel.textColor = Theme.accent
            nodeDot?.live = false
            downValue.stringValue = "0 B/s"
            upValue.stringValue = "0 B/s"
            handshakeValue.stringValue = "—"
            durationValue.stringValue = "—"
            return
        }

        let phase = store.phase(for: name)
        let speed = store.speed(for: name)

        // 按钮 + 状态
        switch phase {
        case .disconnected:
            powerBtn.mode = .disconnected
            powerBtn.stopSpinning()
            statusTitle.stringValue = "未连接"
            statusTitle.textColor = Theme.text
            statusSub.stringValue = "点击按钮启动隧道"
        case .connecting:
            powerBtn.mode = .connecting
            powerBtn.startSpinning()
            statusTitle.stringValue = "连接中…"
            statusTitle.textColor = Theme.orange
            statusSub.stringValue = "正在建立接口"
        case .awaitingHandshake:
            powerBtn.mode = .connecting
            powerBtn.startSpinning()
            statusTitle.stringValue = "等待握手…"
            statusTitle.textColor = Theme.orange
            statusSub.stringValue = "已建立接口，等待对端响应"
        case .connected:
            powerBtn.mode = .connected
            powerBtn.stopSpinning()
            statusTitle.stringValue = "已连接"
            statusTitle.textColor = Theme.green
            statusSub.stringValue = "隧道已加密传输"
        case .failed:
            powerBtn.mode = .failed
            powerBtn.stopSpinning()
            statusTitle.stringValue = "连接失败"
            statusTitle.textColor = Theme.red
            statusSub.stringValue = "点击重试，或查看日志"
        }

        // 速率
        downValue.stringValue = fmtSpeed(speed.down)
        upValue.stringValue = fmtSpeed(speed.up)

        // 节点
        nodeNameLabel.stringValue = name
        nodeNameLabel.textColor = (name == currentProfile) ? Theme.text : Theme.text
        nodeAddrLabel.stringValue = profile.endpoint.isEmpty ? profile.address : profile.endpoint
        nodeAddrLabel.textColor = Theme.faint
        nodeDot?.live = (phase == .connected)

        // 握手 / 时长
        let peer = store.status(for: name)?.peers.first
        if let hs = peer?.latestHandshake {
            handshakeValue.stringValue = fmtHandshake(hs)
            let fresh = Date().timeIntervalSince(hs) < 180
            handshakeValue.textColor = fresh ? Theme.green : Theme.orange
        } else {
            handshakeValue.stringValue = phase.isUp ? "等待握手" : "—"
            handshakeValue.textColor = phase.isUp ? Theme.orange : Theme.faint
        }
        if let dur = store.connectedDuration(for: name) {
            durationValue.stringValue = fmtDuration(dur)
            durationValue.textColor = Theme.text
        } else {
            durationValue.stringValue = "—"
            durationValue.textColor = Theme.faint
        }
    }

    // MARK: 交互
    private func toggleConnect() {
        guard let name = currentProfile else { return }
        let phase = store.phase(for: name)
        switch phase {
        case .disconnected, .failed:
            store.connect(name)
        case .connecting:
            break
        case .awaitingHandshake, .connected:
            store.disconnect(name)
        }
    }

    /// 展开中的下拉浮层
    private var dropdown: DropdownOverlay?
    private var nodeCardRef: NSView?
    private weak var arrowRef: ArrowButton?

    @objc private func showNodeMenu(_ sender: NSButton) {
        let arrow = sender as? ArrowButton
        // 已展开 → 收起
        if let d = dropdown {
            d.dismiss()
            dropdown = nil
            arrow?.expanded = false
            return
        }
        guard let card = nodeCardRef else { return }

        // 没有配置：不弹下拉，直接跳到配置页去添加
        if store.profiles.isEmpty {
            onShowConfig?()
            return
        }

        let items = store.profiles.map { p -> (title: String, subtitle: String, selected: Bool) in
            let sub = p.endpoint.isEmpty ? (p.address.isEmpty ? "—" : p.address) : p.endpoint
            return (p.name, sub, p.name == currentProfile)
        }

        let overlay = DropdownOverlay(
            items: items,
            width: max(card.bounds.width - 8, 240),
            onPick: { [weak self] name in
                self?.pickNode(named: name)
            },
            onDismiss: { [weak self] in
                self?.dropdown = nil
                arrow?.expanded = false
            })
        arrow?.expanded = true
        dropdown = overlay
        // 加到窗口 contentView（最顶层），避免被同页其他卡片遮挡
        guard let host = view.window?.contentView else { return }
        let anchorInHost = card.convert(card.bounds, to: host)
        overlay.present(in: host, anchorRect: anchorInHost)
    }

    private func pickNode(named name: String) {
        currentProfile = name
        (view.window?.windowController as? MainWindowController)?.selectProfile(name)
        update(profileName: name)
    }

    private func fmtSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1 { return "0 B/s" }
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        if bytesPerSec < 1024 * 1024 { return String(format: "%.1f KB/s", bytesPerSec / 1024) }
        return String(format: "%.2f MB/s", bytesPerSec / 1024 / 1024)
    }

    private func fmtDuration(_ s: TimeInterval) -> String {
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
