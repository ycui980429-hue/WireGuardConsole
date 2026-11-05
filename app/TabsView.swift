// TabsView.swift — 日志页 / 配置页 / 底部标签栏
import AppKit

// MARK: - 日志页
final class LogViewController: NSViewController {
    private let store: ProfileStore
    private(set) var profileName: String?
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let titleLabel = label("日志", size: 12, weight: .semibold, color: Theme.text)
    private var lastCount = -1
    /// 空态提示（覆盖在滚动区中央）
    private let emptyLabel: NSTextField = {
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .systemFont(ofSize: 14)
        l.textColor = Theme.faint
        l.alignment = .center
        l.isHidden = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

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

        textView.isEditable = false
        textView.isRichText = false
        textView.font = monoFont(12)
        textView.textColor = Theme.text
        textView.backgroundColor = .clear
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 12, height: 10)

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.card
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = Theme.cardBorder.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = NSButton(title: "复制", target: self, action: #selector(copyAll(_:)))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small
        let clearBtn = NSButton(title: "清空", target: self, action: #selector(clearAll(_:)))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small

        let header = NSStackView(views: [titleLabel, NSView(), copyBtn, clearBtn])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(scroll)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
    }

    func setProfile(_ name: String?) {
        if profileName != name {
            profileName = name
            lastCount = -1
        }
        titleLabel.stringValue = name.map { "日志 · \($0)" } ?? "日志"
    }

    func refresh() {
        guard let name = profileName else {
            showEmptyMessage("未选择配置")
            return
        }
        let lines = store.logLines(for: name)
        guard lines.count != lastCount else { return }
        lastCount = lines.count
        if !lines.isEmpty { hideEmptyMessage() }

        let attr = NSMutableAttributedString()
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        for line in lines {
            let color: NSColor
            switch line.level {
            case .info: color = Theme.muted
            case .warn: color = Theme.orange
            case .error: color = Theme.red
            case .success: color = Theme.green
            }
            attr.append(NSAttributedString(
                string: "[\(f.string(from: line.time))] \(line.text)\n",
                attributes: [.font: monoFont(12), .foregroundColor: color]))
        }
        if attr.length == 0 {
            showEmptyMessage("暂无日志\n连接后会显示 wg-quick 的完整输出与诊断")
            return
        }
        textView.textStorage?.setAttributedString(attr)
        textView.scrollToEndOfDocument(nil)
    }

    /// 空态提示：灰色 14px，居中显示在滚动区中央
    private func showEmptyMessage(_ text: String) {
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
        textView.string = ""
        lastCount = -2
    }

    private func hideEmptyMessage() {
        emptyLabel.isHidden = true
        if lastCount == -2 { lastCount = -1 }
    }

    @objc private func copyAll(_ sender: Any?) {
        guard let name = profileName else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        copyText(store.logLines(for: name).map { "[\(f.string(from: $0.time))] \($0.text)" }
            .joined(separator: "\n"))
    }
    @objc private func clearAll(_ sender: Any?) {
        guard let name = profileName else { return }
        store.clearLogs(for: name)
        refresh()
    }
}

// MARK: - 配置页
final class ConfigViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ProfileStore
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyHint = label("还没有配置，点击右上角「导入配置」", size: 12, color: Theme.faint)

    /// 选中某条配置（只更新当前项，不跳页）
    var onSelect: ((String) -> Void)?
    var onImport: (() -> Void)?
    var onKeys: (() -> Void)?
    var onDelete: ((String) -> Void)?
    var onEdit: ((String) -> Void)?
    var onConnect: ((String) -> Void)?

    private var profiles: [Profile] = []
    /// 当前正在操作的配置（决定是否显示"已连接"样式）
    private(set) var activeName: String?

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

        let title = label("配置", size: 12, weight: .semibold, color: Theme.text)
        let countLabel = label("", size: 12, color: Theme.faint)
        countLabel.identifier = NSUserInterfaceItemIdentifier("count")

        let importBtn = NSButton(title: "导入", target: self, action: #selector(importTapped(_:)))
        importBtn.bezelStyle = .rounded
        importBtn.controlSize = .small
        importBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        importBtn.imagePosition = .imageLeading

        let keysBtn = NSButton(title: "密钥", target: self, action: #selector(keysTapped(_:)))
        keysBtn.bezelStyle = .rounded
        keysBtn.controlSize = .small
        keysBtn.image = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil)
        keysBtn.imagePosition = .imageLeading

        let titleCol = NSStackView(views: [title, countLabel])
        titleCol.orientation = .horizontal
        titleCol.alignment = .firstBaseline
        titleCol.spacing = 6

        let header = NSStackView(views: [titleCol, NSView(), keysBtn, importBtn])
        header.orientation = .horizontal
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = 78
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none     // 自己画选中态，避免系统蓝底
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.sizeLastColumnToFit()

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        emptyHint.isHidden = true

        view.addSubview(header)
        view.addSubview(scroll)
        view.addSubview(emptyHint)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),

            emptyHint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func importTapped(_ sender: Any?) { onImport?() }
    @objc private func keysTapped(_ sender: Any?) { onKeys?() }

    func reload(profiles: [Profile], activeName: String?) {
        let changed = profiles != self.profiles || activeName != self.activeName
        self.profiles = profiles
        self.activeName = activeName
        if changed { table.reloadData() }
        emptyHint.isHidden = !profiles.isEmpty
        if let c = view.subviews.compactMap({ $0 as? NSStackView })
            .flatMap({ $0.arrangedSubviews })
            .compactMap({ $0 as? NSStackView })
            .flatMap({ $0.arrangedSubviews })
            .first(where: { $0.identifier?.rawValue == "count" }) as? NSTextField {
            c.stringValue = profiles.isEmpty ? "" : "\(profiles.count) 个"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    // MARK: 行视图
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = profiles[row]
        let isActive = (p.name == activeName)
        let phase = store.phase(for: p.name)

        let wrapper = NSView()
        wrapper.identifier = NSUserInterfaceItemIdentifier(p.name)
        wrapper.autoresizingMask = [.width]

        // 卡片容器（留出上下 4pt 间距做分隔）
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.borderColor = isActive ? Theme.accent.withAlphaComponent(0.45) : Theme.cardBorder
        card.addSubview(NSView())   // 占位防止空卡不绘制
        wrapper.addSubview(card)

        // 状态点
        let dot = StatusDotView(live: phase == .connected)
        dot.translatesAutoresizingMaskIntoConstraints = false

        // 名称
        let name = label(p.name, size: 12, weight: .medium, color: isActive ? Theme.accent : Theme.text)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        // 副标题：endpoint / 地址
        let sub = p.endpoint.isEmpty ? (p.address.isEmpty ? "—" : p.address) : p.endpoint
        let subLabel = label(sub, size: 12, color: Theme.faint)
        subLabel.lineBreakMode = .byTruncatingMiddle
        subLabel.translatesAutoresizingMaskIntoConstraints = false

        // 状态文字
        let statusText: String
        let statusColor: NSColor
        switch phase {
        case .connected: statusText = "已连接"; statusColor = Theme.green
        case .connecting, .awaitingHandshake: statusText = "连接中"; statusColor = Theme.orange
        case .failed: statusText = "失败"; statusColor = Theme.red
        case .disconnected: statusText = isActive ? "当前" : ""; statusColor = Theme.faint
        }
        let status = label(statusText, size: 12, weight: .medium, color: statusColor)
        status.translatesAutoresizingMaskIntoConstraints = false

        let textCol = NSStackView(views: [name, subLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.translatesAutoresizingMaskIntoConstraints = false

        // 操作按钮：连接 / 编辑 / 删除
        let connectBtn = makeIconButton("power", tooltip: phase.isUp ? "断开" : "连接",
                                        tint: phase.isUp ? Theme.orange : Theme.green)
        connectBtn.target = self
        connectBtn.action = #selector(connectRow(_:))
        connectBtn.identifier = NSUserInterfaceItemIdentifier(p.name)

        let editBtn = makeIconButton("square.and.pencil", tooltip: "编辑", tint: Theme.accent)
        editBtn.target = self
        editBtn.action = #selector(editRow(_:))
        editBtn.identifier = NSUserInterfaceItemIdentifier(p.name)

        let delBtn = makeIconButton("trash", tooltip: "删除", tint: Theme.red)
        delBtn.target = self
        delBtn.action = #selector(deleteRow(_:))
        delBtn.identifier = NSUserInterfaceItemIdentifier(p.name)

        let actions = NSStackView(views: [connectBtn, editBtn, delBtn])
        actions.orientation = .horizontal
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(dot)
        card.addSubview(textCol)
        card.addSubview(status)
        card.addSubview(actions)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -3),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),

            dot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            textCol.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            textCol.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textCol.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -6),

            status.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            actions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        // 点卡片空白处 = 选中（不跳页）
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
        wrapper.addGestureRecognizer(click)
        wrapper.identifier = NSUserInterfaceItemIdentifier(p.name)
        return wrapper
    }

    private func makeIconButton(_ symbol: String, tooltip: String, tint: NSColor) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.title = ""
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        b.contentTintColor = tint
        b.toolTip = tooltip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    @objc private func rowTapped(_ g: NSClickGestureRecognizer) {
        guard let name = g.view?.identifier?.rawValue, !name.isEmpty else { return }
        onSelect?(name)       // 只更新选中项，不跳首页
    }

    @objc private func connectRow(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onConnect?(name)
    }

    @objc private func editRow(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onEdit?(name)
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onDelete?(name)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { }
}

// MARK: - 底部标签栏
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var buttons: [NSButton] = []
    private let titles = ["首页", "日志", "配置"]
    private let symbols = ["house.fill", "doc.text.fill", "slider.horizontal.3"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])

        for (i, title) in titles.enumerated() {
            let btn = NSButton(title: title, target: self, action: #selector(tap(_:)))
            btn.tag = i
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: symbols[i], accessibilityDescription: title)
            btn.imagePosition = .imageAbove
            btn.font = .systemFont(ofSize: 12, weight: .medium)
            btn.contentTintColor = (i == 0) ? Theme.accent : Theme.faint
            buttons.append(btn)
            stack.addArrangedSubview(btn)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap(_ sender: NSButton) {
        select(sender.tag)
        onSelect?(selectedIndex)
    }

    /// 编程式切换高亮（不触发 onSelect，避免循环）
    func select(_ index: Int) {
        guard index >= 0, index < buttons.count else { return }
        selectedIndex = index
        for (i, b) in buttons.enumerated() {
            b.contentTintColor = (i == selectedIndex) ? Theme.accent : Theme.faint
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 顶部分隔线
        Theme.cardBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
