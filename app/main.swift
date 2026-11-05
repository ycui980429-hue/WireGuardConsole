// main.swift — WireGuard 控制台 · 原生 AppKit 界面
// 结构：侧边栏（配置列表，材质背景）+ 详情（状态/统计/操作）+ 菜单栏常驻快速控制
import AppKit

// MARK: - 工具

func copyText(_ text: String) {
    guard !text.isEmpty else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

func fmtBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
}

func fmtHandshake(_ date: Date?) -> String {
    guard let date else { return "从未握手" }
    let s = Int(Date().timeIntervalSince(date))
    if s < 0 { return date.formatted() }
    if s < 120 { return "\(s) 秒前" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 172800 { return "\(s / 3600) 小时前" }
    return "超过 2 天未握手"
}

func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: weight)
}

/// 状态圆点：实心 + 连接时的外环
final class StatusDotView: NSView {
    var live: Bool { didSet { needsDisplay = true } }
    init(live: Bool) {
        self.live = live
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        if live {
            NSColor.systemGreen.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let fill: NSColor = live ? .systemGreen : .secondaryLabelColor
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
    }
}

// MARK: - 应用代理

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ProfileStore()
    var windowController: MainWindowController?
    var statusItem: NSStatusItem?
    var statusMenu: StatusMenu?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WG.ensureDirs()

        let wc = MainWindowController(store: store)
        windowController = wc
        wc.showWindow(nil)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "lock.shield",
                                   accessibilityDescription: "WireGuard 控制台")
        }
        statusItem = item
        let menu = StatusMenu(appDelegate: self)
        statusMenu = menu
        item.menu = menu

        store.onChange = { [weak self] in self?.syncUI() }
        store.onError = { [weak self] title, message in
            self?.windowController?.presentErrorSheet(title: title, message: message)
        }
        store.startPolling(every: 5)
        syncUI()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    func syncUI() {
        windowController?.reload()
        guard let button = statusItem?.button else { return }
        let live = store.activeCount > 0
        button.image = NSImage(systemSymbolName: live ? "lock.shield.fill" : "lock.shield",
                               accessibilityDescription: "WireGuard 控制台")
        button.toolTip = live ? "WireGuard：\(store.activeCount) 条隧道已连接" : "WireGuard：未连接"
    }

    @objc func showMainWindow(_ sender: Any?) {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if store.phase(for: name).isUp { store.disconnect(name) } else { store.connect(name) }
    }
}

// MARK: - 菜单栏菜单

final class StatusMenu: NSMenu, NSMenuDelegate {
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(title: "WireGuard 控制台")
        delegate = self
        autoenablesItems = false
    }
    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        guard let store = appDelegate?.store else { return }

        let summary = NSMenuItem(title: store.profiles.isEmpty
            ? "暂无配置"
            : "\(store.profiles.count) 个配置 · \(store.activeCount) 条活动",
            action: nil, keyEquivalent: "")
        summary.isEnabled = false
        addItem(summary)
        addItem(.separator())

        for p in store.profiles {
            let phase = store.phase(for: p.name)
            let busy = store.busy.contains(p.name)
            let item = NSMenuItem(
                title: busy ? "\(p.name)（进行中…）"
                    : (phase.isUp ? "断开 \(p.name)" : "连接 \(p.name)"),
                action: busy ? nil : #selector(AppDelegate.toggleProfile(_:)),
                keyEquivalent: "")
            item.target = appDelegate
            item.representedObject = p.name
            item.image = NSImage(systemSymbolName: phase.isUp ? "stop.fill" : "play.fill",
                                 accessibilityDescription: nil)
            addItem(item)
        }
        if store.profiles.isEmpty {
            let hint = NSMenuItem(title: "打开控制台导入配置", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            addItem(hint)
        }
        addItem(.separator())
        let open = NSMenuItem(title: "打开控制台", action: #selector(AppDelegate.showMainWindow(_:)),
                              keyEquivalent: "o")
        open.keyEquivalentModifierMask = []
        open.target = appDelegate
        addItem(open)
        addItem(NSMenuItem(title: "退出 WireGuard 控制台",
                           action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

// MARK: - 主菜单

func buildMainMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "关于 WireGuard 控制台",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "退出 WireGuard 控制台",
                               action: #selector(NSApplication.terminate(_:)),
                               keyEquivalent: "q"))
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
    editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
    editMenu.addItem(.separator())
    editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = editMenu

    let windowItem = NSMenuItem()
    main.addItem(windowItem)
    let windowMenu = NSMenu(title: "窗口")
    windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)),
                                  keyEquivalent: "m"))
    windowMenu.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)),
                                  keyEquivalent: "w"))
    windowItem.submenu = windowMenu

    NSApp.mainMenu = main
}

// MARK: - 主窗口（卡片式单页）

final class MainWindowController: NSObject, NSWindowDelegate {
    let store: ProfileStore
    let window: NSWindow
    private let home: HomeViewController
    private let logs: LogViewController
    private let config: ConfigViewController
    private let tabBar = TabBarView()
    private let pageContainer = NSView()
    private var currentPage: NSViewController?
    private var activeSheet: NSObject?
    private(set) var selectedProfile: String?

    init(store: ProfileStore) {
        self.store = store
        home = HomeViewController(store: store)
        logs = LogViewController(store: store)
        config = ConfigViewController(store: store)

        // 窗口尺寸参考移动端卡片比例（窄而高）
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "WireGuard"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.bg
        window.minSize = NSSize(width: 380, height: 560)
        window.appearance = NSAppearance(named: .aqua)
        super.init()
        window.delegate = self

        buildUI()
        wireCallbacks()
        window.center()
        _ = window.setFrameAutosaveName("WGMainWindow5")
        selectProfile(store.profiles.first?.name)
    }

    private func buildUI() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = root

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] idx in self?.showPage(idx) }

        root.addSubview(pageContainer)
        root.addSubview(tabBar)
        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: root.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 54),
        ])
        showPage(0)
    }

    private func wireCallbacks() {
        // 选中只更新当前配置，不跳转页面
        config.onSelect = { [weak self] name in
            self?.selectProfile(name)
            self?.reload()
        }
        home.onShowConfig = { [weak self] in self?.showPage(2) }
        config.onImport = { [weak self] in self?.presentImportSheet() }
        config.onKeys = { [weak self] in self?.presentKeysSheet() }
        config.onConnect = { [weak self] name in
            guard let self else { return }
            if self.store.phase(for: name).isUp { self.store.disconnect(name) }
            else { self.store.connect(name) }
        }
        config.onEdit = { [weak self] name in self?.presentEditSheet(name) }
        config.onDelete = { [weak self] name in self?.confirmDelete(name) }
    }

    /// 删除前确认（自定义弹窗，与整体风格一致）
    private func confirmDelete(_ name: String) {
        let c = DeleteConfirmController(profileName: name,
                                        isConnected: store.phase(for: name).isUp)
        c.onClose = { [weak self] in self?.activeSheet = nil }
        c.onConfirm = { [weak self] in
            self?.store.delete(name)
            self?.activeSheet = nil
        }
        activeSheet = c
        c.beginAsSheet(of: window)
    }

    /// 编辑配置：复用导入弹窗，预填内容
    private func presentEditSheet(_ name: String) {
        let c = ImportSheetController(store: store, editing: name)
        c.onClose = { [weak self] in self?.activeSheet = nil }
        activeSheet = c
        c.beginAsSheet(of: window)
    }

    private func showPage(_ idx: Int) {
        tabBar.select(idx)          // 导航高亮跟着切换
        currentPage?.view.removeFromSuperview()
        let vc: NSViewController = [home, logs, config][idx]
        currentPage = vc
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
        ])
        reload()
    }

    func selectProfile(_ name: String?) {
        guard let name, store.profiles.contains(where: { $0.name == name }) else {
            selectedProfile = store.profiles.first?.name
            return
        }
        selectedProfile = name
    }

    func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(sender)
    }

    func reload() {
        selectProfile(selectedProfile)
        home.update(profileName: selectedProfile)
        logs.setProfile(selectedProfile)
        logs.refresh()
        config.reload(profiles: store.profiles, activeName: selectedProfile)
    }

    func presentImportSheet() {
        let c = ImportSheetController(store: store)
        c.onClose = { [weak self] in self?.activeSheet = nil }
        activeSheet = c
        c.beginAsSheet(of: window)
    }

    func presentKeysSheet() {
        let c = KeysSheetController()
        c.onClose = { [weak self] in self?.activeSheet = nil }
        activeSheet = c
        c.beginAsSheet(of: window)
    }

    func presentErrorSheet(title: String, message: String) {
        let c = ErrorSheetController(title: title, message: message)
        c.onClose = { [weak self] in self?.activeSheet = nil }
        activeSheet = c
        c.beginAsSheet(of: window)
    }
}

// MARK: - 导入弹窗

final class ImportSheetController: NSObject, NSTextViewDelegate {
    var onClose: (() -> Void)?
    private let store: ProfileStore
    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let nameField = VerticallyCenteredTextField()
    private let textView = NSTextView()
    private var showingPlaceholder = false
    private static let placeholderText = """
[Interface]
PrivateKey = 填写你的私钥
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = 填写服务端公钥
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""

    private let errorLabel = NSTextField(labelWithString: "")
    private let errorBox = NSView()
    private var dropZone: DropZoneView!
    private var okBtn: NSButton?
    private let editingName: String?

    init(store: ProfileStore, editing: String? = nil) {
        self.store = store
        self.editingName = editing
        super.init()
        buildUI()
    }

    // MARK: 小构件
    private func sectionCard(_ views: [NSView], spacing: CGFloat = 8) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Theme.cardBorder.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    private func caption(_ text: String) -> NSTextField {
        label(text, size: 12, weight: .semibold, color: Theme.text)
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = Theme.faint
        l.maximumNumberOfLines = 2
        return l
    }


    private func buildUI() {
        sheet.title = editingName == nil ? "导入配置" : "编辑配置"
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.backgroundColor = Theme.bg

        // ── 头部 ──
        let headIcon = NSImageView()
        headIcon.image = NSImage(systemSymbolName: editingName == nil
                                 ? "square.and.arrow.down" : "square.and.pencil",
                                 accessibilityDescription: nil)
        headIcon.contentTintColor = Theme.accent
        headIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        headIcon.translatesAutoresizingMaskIntoConstraints = false
        headIcon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        headIcon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let headTitle = label(editingName == nil ? "导入 WireGuard 配置" : "编辑配置",
                              size: 12, weight: .semibold, color: Theme.text)
        let headSub = label("支持拖入文件或直接粘贴内容", size: 12, color: Theme.muted)
        let headCol = NSStackView(views: [headTitle, headSub])
        headCol.orientation = .vertical
        headCol.alignment = .leading
        headCol.spacing = 2
        let head = NSStackView(views: [headIcon, headCol])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10
        head.translatesAutoresizingMaskIntoConstraints = false

        // ── 拖放区 ──
        dropZone = DropZoneView()
        dropZone.onPick = { [weak self] in self?.pickFile(nil) }
        dropZone.onFile = { [weak self] url in self?.loadFile(url) }
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.heightAnchor.constraint(equalToConstant: 64).isActive = true

        // ── 名称 ──
        nameField.placeholderString = "例如 office-vpn"
        nameField.font = .systemFont(ofSize: 12)
        nameField.isBezeled = false
        nameField.drawsBackground = true
        nameField.backgroundColor = Theme.bg
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = 7
        nameField.layer?.borderWidth = 1
        nameField.layer?.borderColor = Theme.cardBorder.cgColor
        nameField.focusRingType = .none
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        // 文字左内边距：NSTextField 直接设 layer 圆角后，文字会贴左边框
        nameField.cell?.usesSingleLineMode = true

        // 套一层容器做内边距（纯 NSTextField 加 layer 圆角时文字会贴边）
        let nameWrap = NSView()
        nameWrap.wantsLayer = true
        nameWrap.layer?.backgroundColor = Theme.bg.cgColor
        nameWrap.layer?.cornerRadius = 7
        nameWrap.layer?.borderWidth = 1
        nameWrap.layer?.borderColor = Theme.cardBorder.cgColor
        nameWrap.translatesAutoresizingMaskIntoConstraints = false
        nameWrap.heightAnchor.constraint(equalToConstant: 30).isActive = true
        nameField.backgroundColor = .clear
        nameField.wantsLayer = false
        nameField.layer?.borderWidth = 0
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameWrap.addSubview(nameField)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: nameWrap.leadingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: nameWrap.trailingAnchor, constant: -10),
            nameField.centerYAnchor.constraint(equalTo: nameWrap.centerYAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 18),
        ])

        let nameCard = sectionCard([
            caption("配置名称"),
            hintLabel("英文字母、数字和 _ = + . -，最多 15 个字符"),
            nameWrap,
        ], spacing: 6)

        // ── 内容 ──
        textView.font = monoFont(12)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self
        textView.backgroundColor = Theme.bg
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = true
        textScroll.backgroundColor = Theme.bg
        textScroll.wantsLayer = true
        textScroll.layer?.cornerRadius = 7
        textScroll.layer?.borderWidth = 1
        textScroll.layer?.borderColor = Theme.cardBorder.cgColor
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let contentCard = sectionCard([
            caption("配置内容"),
            hintLabel("粘贴 WireGuard 客户端配置，或拖入 .conf 文件自动填入"),
            textScroll,
        ], spacing: 6)

        // ── 错误提示 ──
        errorBox.wantsLayer = true
        errorBox.layer?.backgroundColor = Theme.red.withAlphaComponent(0.09).cgColor
        errorBox.layer?.cornerRadius = 8
        errorBox.isHidden = true
        errorBox.translatesAutoresizingMaskIntoConstraints = false

        let errIcon = NSImageView()
        errIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                accessibilityDescription: nil)
        errIcon.contentTintColor = Theme.red
        errIcon.translatesAutoresizingMaskIntoConstraints = false
        errIcon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        errIcon.heightAnchor.constraint(equalToConstant: 13).isActive = true

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = Theme.red
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3

        let errRow = NSStackView(views: [errIcon, errorLabel])
        errRow.orientation = .horizontal
        errRow.alignment = .top
        errRow.spacing = 7
        errRow.translatesAutoresizingMaskIntoConstraints = false
        errorBox.addSubview(errRow)
        NSLayoutConstraint.activate([
            errRow.leadingAnchor.constraint(equalTo: errorBox.leadingAnchor, constant: 10),
            errRow.trailingAnchor.constraint(equalTo: errorBox.trailingAnchor, constant: -10),
            errRow.topAnchor.constraint(equalTo: errorBox.topAnchor, constant: 8),
            errRow.bottomAnchor.constraint(equalTo: errorBox.bottomAnchor, constant: -8),
        ])

        // ── 底部按钮 ──
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: editingName == nil ? "导入" : "保存",
                          target: self, action: #selector(doImport(_:)))
        ok.bezelStyle = .rounded
        ok.controlSize = .large
        ok.bezelColor = Theme.accent
        ok.keyEquivalent = "\r"
        okBtn = ok

        let buttons = NSStackView(views: [NSView(), cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // ── 组装 ──
        let stack = NSStackView(views: [head, dropZone, nameCard, contentCard, errorBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: head)
        stack.setCustomSpacing(8, after: dropZone)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        sheet.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            dropZone.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            nameCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            contentCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            textScroll.widthAnchor.constraint(equalTo: contentCard.widthAnchor, constant: -28),
            nameWrap.widthAnchor.constraint(equalTo: nameCard.widthAnchor, constant: -28),
            errorBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    func beginAsSheet(of window: NSWindow) {
        errorBox.isHidden = true
        dropZone.reset()
        if let name = editingName {
            nameField.stringValue = name
            nameField.isEditable = true      // 编辑时也允许改名称
            nameField.alphaValue = 1
            showingPlaceholder = false
            textView.textColor = Theme.text
            if let text = try? String(contentsOf: WG.profileURL(name), encoding: .utf8) {
                textView.string = text
                dropZone.showLoaded(name + ".conf")
            }
        } else {
            nameField.isEditable = true
            nameField.alphaValue = 1
            nameField.stringValue = ""
            showPlaceholder()
        }
        window.beginSheet(sheet) { [self] _ in onClose?() }
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        if showingPlaceholder {
            // 用户开始输入：清掉示例
            showingPlaceholder = false
            textView.string = ""
            textView.textColor = Theme.text
        }
    }

    /// 显示灰色示例文本（用户一旦输入或导入就清除）
    private func showPlaceholder() {
        showingPlaceholder = true
        textView.string = Self.placeholderText
        textView.textColor = NSColor.placeholderTextColor
        textView.font = monoFont(12)
    }

    private func clearPlaceholderIfNeeded() {
        guard showingPlaceholder else { return }
        showingPlaceholder = false
        textView.string = ""
        textView.textColor = Theme.text
    }

    private func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            showError("无法读取该文件")
            return
        }
        clearPlaceholderIfNeeded()
        textView.string = content
        textView.textColor = Theme.text
        if editingName == nil {
            nameField.stringValue = url.deletingPathExtension().lastPathComponent
        }
        dropZone.showLoaded(url.lastPathComponent)
        errorBox.isHidden = true
    }

    @objc private func pickFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "选择 WireGuard 配置文件（.conf）"
        panel.beginSheetModal(for: sheet) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.loadFile(url)
        }
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorBox.isHidden = false
    }

    @objc private func cancel(_ sender: Any?) { sheet.sheetParent?.endSheet(sheet) }

    @objc private func doImport(_ sender: Any?) {
        if showingPlaceholder {
            showError("请先粘贴或导入配置内容")
            return
        }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        do {
            try WG.saveProfile(name: newName, text: textView.string, renamingFrom: editingName)
            store.refresh()
            sheet.sheetParent?.endSheet(sheet)
        } catch {
            showError(error.localizedDescription)
        }
    }
}

// MARK: - 拖放区
final class DropZoneView: NSView {
    var onPick: (() -> Void)?
    var onFile: ((URL) -> Void)?
    private var loadedName: String?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        loadedName = nil
        hovering = false
        needsDisplay = true
    }

    func showLoaded(_ name: String) {
        loadedName = name
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        (hovering ? Theme.accent.withAlphaComponent(0.08) : NSColor.white).setFill()
        path.fill()
        (hovering ? Theme.accent : Theme.cardBorder).setStroke()
        path.lineWidth = hovering ? 1.5 : 1
        if !hovering {
            path.setLineDash([5, 4], count: 2, phase: 0)
        }
        path.stroke()

        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        if let name = loadedName {
            drawText("已载入：\(name)", at: NSPoint(x: c.x, y: c.y - 8),
                     size: 12, weight: .medium, color: Theme.green)
            drawText("点击可重新选择", at: NSPoint(x: c.x, y: c.y - 26),
                     size: 12, weight: .regular, color: Theme.faint)
        } else {
            drawText("拖入 .conf 文件，或点击选择", at: NSPoint(x: c.x, y: c.y - 8),
                     size: 12, weight: .medium, color: Theme.text)
            drawText("支持 WireGuard 标准配置文件", at: NSPoint(x: c.x, y: c.y - 26),
                     size: 12, weight: .regular, color: Theme.faint)
        }
    }

    private func drawText(_ s: String, at center: NSPoint, size: CGFloat,
                          weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y))
    }

    // 点击选择
    override func mouseDown(with event: NSEvent) { onPick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // 拖放
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering = true; needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        hovering = false; needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false
        needsDisplay = true
        guard let url = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL
        else { return false }
        onFile?(url)
        return true
    }
}

// MARK: - 密钥弹窗

final class KeysSheetController: NSObject {
    var onClose: (() -> Void)?
    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private var groups: [NSView] = []
    private var values: [String] = ["", "", ""]
    private var valueLabels: [NSTextField] = []
    private let errorLabel = label("", size: 12, color: Theme.red)

    private let entries: [(title: String, hint: String, symbol: String, color: NSColor)] = [
        ("Private Key", "仅自己保留，绝不外传", "lock.fill",
         NSColor(red: 0.83, green: 0.24, blue: 0.20, alpha: 1)),
        ("Public Key", "提供给对方 / 服务器", "person.2.fill",
         NSColor(red: 0.13, green: 0.65, blue: 0.34, alpha: 1)),
        ("Preshared Key", "可选，额外加密层", "shield.lefthalf.filled",
         NSColor(red: 0.20, green: 0.47, blue: 0.90, alpha: 1)),
    ]

    func beginAsSheet(of window: NSWindow) {
        groups = []
        valueLabels = []
        sheet.title = "生成密钥"
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.backgroundColor = Theme.bg

        // 头部
        let headIcon = NSImageView()
        headIcon.image = NSImage(systemSymbolName: "key.horizontal.fill",
                                 accessibilityDescription: nil)
        headIcon.contentTintColor = Theme.accent
        headIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        headIcon.translatesAutoresizingMaskIntoConstraints = false
        headIcon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        headIcon.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let headTitle = label("密钥对", size: 12, weight: .semibold, color: Theme.text)
        let headSub = label("用于 WireGuard 节点认证", size: 12, color: Theme.muted)
        let headCol = NSStackView(views: [headTitle, headSub])
        headCol.orientation = .vertical
        headCol.alignment = .leading
        headCol.spacing = 2
        let head = NSStackView(views: [headIcon, headCol])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10
        head.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [head])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: head)

        // 每个密钥一张白卡
        for (i, e) in entries.enumerated() {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.white.cgColor
            card.layer?.cornerRadius = 10
            card.layer?.borderWidth = 1
            card.layer?.borderColor = Theme.cardBorder.cgColor
            card.translatesAutoresizingMaskIntoConstraints = false

            // 左侧图标圆底
            let iconBg = NSView()
            iconBg.wantsLayer = true
            iconBg.layer?.backgroundColor = e.color.withAlphaComponent(0.12).cgColor
            iconBg.layer?.cornerRadius = 13
            iconBg.translatesAutoresizingMaskIntoConstraints = false
            iconBg.widthAnchor.constraint(equalToConstant: 26).isActive = true
            iconBg.heightAnchor.constraint(equalToConstant: 26).isActive = true

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)
            icon.contentTintColor = e.color
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            icon.translatesAutoresizingMaskIntoConstraints = false
            iconBg.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            ])

            let title = label(e.title, size: 12, weight: .semibold, color: Theme.text)
            let hint = label(e.hint, size: 12, color: Theme.faint)
            let titleRow = NSStackView(views: [title, hint])
            titleRow.orientation = .horizontal
            titleRow.alignment = .firstBaseline
            titleRow.spacing = 6

            let value = NSTextField(labelWithString: "生成中…")
            value.font = monoFont(12)
            value.lineBreakMode = .byTruncatingMiddle
            value.isSelectable = true
            value.textColor = Theme.faint
            value.translatesAutoresizingMaskIntoConstraints = false
            valueLabels.append(value)

            let copy = NSButton(title: "复制", target: self, action: #selector(copyValue(_:)))
            copy.bezelStyle = .rounded
            copy.controlSize = .mini
            copy.tag = i
            copy.translatesAutoresizingMaskIntoConstraints = false

            let topRow = NSStackView(views: [iconBg, titleRow, NSView(), copy])
            topRow.orientation = .horizontal
            topRow.alignment = .centerY
            topRow.spacing = 8
            topRow.translatesAutoresizingMaskIntoConstraints = false

            let col = NSStackView(views: [topRow, value])
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 6
            col.translatesAutoresizingMaskIntoConstraints = false

            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                topRow.widthAnchor.constraint(equalTo: col.widthAnchor),
                value.widthAnchor.constraint(equalTo: col.widthAnchor),
            ])
            groups.append(card)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }

        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true

        let regen = NSButton(title: "重新生成", target: self, action: #selector(regenTapped(_:)))
        regen.bezelStyle = .rounded
        regen.controlSize = .large
        regen.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        regen.imagePosition = .imageLeading
        let close = NSButton(title: "完成", target: self, action: #selector(closeTapped(_:)))
        close.bezelStyle = .rounded
        close.controlSize = .large
        close.bezelColor = Theme.accent
        close.keyEquivalent = "\r"
        let buttons = NSStackView(views: [regen, NSView(), close])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        stack.setCustomSpacing(14, after: groups.last!)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        sheet.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        if let content = sheet.contentView {
            content.layoutSubtreeIfNeeded()
            let st = content.subviews.compactMap { $0 as? NSStackView }.first
            let contentH = st?.fittingSize.height ?? content.fittingSize.height
            if contentH > 100 {
                let h = min(contentH + 2, 600)
                var f = sheet.frame
                f.origin.y += f.height - h
                f.size.height = h
                sheet.setFrame(f, display: false)
            }
        }
        window.beginSheet(sheet) { [self] _ in onClose?() }
        regenerate()
    }

    private func regenerate() {
        errorLabel.isHidden = true
        for f in valueLabels {
            f.stringValue = "生成中…"
            f.textColor = Theme.faint
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let keys = try WG.genKeys()
                DispatchQueue.main.async {
                    self.values = [keys.priv, keys.pub, keys.psk]
                    for (i, f) in self.valueLabels.enumerated() where i < self.values.count {
                        f.stringValue = self.values[i].isEmpty ? "（未生成）" : self.values[i]
                        f.textColor = Theme.text
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorLabel.stringValue = error.localizedDescription
                    self.errorLabel.isHidden = false
                    for f in self.valueLabels {
                        f.stringValue = "生成失败"
                        f.textColor = Theme.red
                    }
                }
            }
        }
    }

    @objc private func copyValue(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < values.count, !values[idx].isEmpty else { return }
        copyText(values[idx])
        sender.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { sender.title = "复制" }
    }
    @objc private func regenTapped(_ sender: Any?) { regenerate() }
    @objc private func closeTapped(_ sender: Any?) { sheet.sheetParent?.endSheet(sheet) }
}

// MARK: - 错误弹窗

final class ErrorSheetController: NSObject {
    var onClose: (() -> Void)?
    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let titleLabel = NSTextField(labelWithString: "")
    private let message = NSTextView()
    private var built = false

    private let errorTitle: String
    private let errorText: String

    init(title: String, message: String) {
        errorTitle = "操作失败 · \(title)"
        errorText = message
        super.init()
    }

    private func buildUI() {
        sheet.title = "操作失败"
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        message.font = monoFont(12)
        message.isEditable = false
        message.isRichText = false
        message.autoresizingMask = [.width]
        message.isVerticallyResizable = true
        let messageScroll = NSScrollView()
        messageScroll.documentView = message
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageScroll.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "复制输出", target: self, action: #selector(copyAll(_:)))
        copy.bezelStyle = .rounded
        let ok = NSButton(title: "好", target: self, action: #selector(closeTapped(_:)))
        ok.bezelStyle = .rounded
        ok.bezelColor = .controlAccentColor
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [copy, NSView(), ok])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        sheet.contentView = content
        content.addSubview(titleLabel)
        content.addSubview(messageScroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            messageScroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            messageScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            messageScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            messageScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        built = true
    }

    func beginAsSheet(of window: NSWindow) {
        if !built { buildUI() }
        titleLabel.stringValue = errorTitle
        message.string = errorText
        window.beginSheet(sheet) { [self] _ in onClose?() }
    }

    @objc private func copyAll(_ sender: Any?) { copyText(message.string) }
    @objc private func closeTapped(_ sender: Any?) { sheet.sheetParent?.endSheet(sheet) }
}

// MARK: - 启动

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
buildMainMenu()
app.run()

// MARK: - 删除确认弹窗

final class DeleteConfirmController: NSObject {
    var onClose: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let profileName: String
    private let isConnected: Bool
    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 210),
                                 styleMask: [.titled], backing: .buffered, defer: false)

    init(profileName: String, isConnected: Bool) {
        self.profileName = profileName
        self.isConnected = isConnected
        super.init()
        buildUI()
    }

    private func buildUI() {
        sheet.title = "删除配置"
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.backgroundColor = Theme.bg

        // 红色警示图标
        let iconBg = NSView()
        iconBg.wantsLayer = true
        iconBg.layer?.backgroundColor = Theme.red.withAlphaComponent(0.11).cgColor
        iconBg.layer?.cornerRadius = 24
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.widthAnchor.constraint(equalToConstant: 48).isActive = true
        iconBg.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: nil)
        icon.contentTintColor = Theme.red
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBg.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
        ])

        let title = label("删除这个配置？", size: 12, weight: .semibold, color: Theme.text)
        title.alignment = .center

        let nameLabel = label(profileName, size: 12, weight: .medium, color: Theme.accent)
        nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)

        var detailText = "配置文件将被永久删除，此操作无法撤销。"
        if isConnected { detailText = "该配置正在连接，将先自动断开。\n配置文件会被永久删除，此操作无法撤销。" }
        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Theme.muted
        detail.alignment = .center

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped(_:)))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"

        let confirm = NSButton(title: "删除", target: self, action: #selector(confirmTapped(_:)))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .large
        confirm.bezelColor = Theme.red
        confirm.keyEquivalent = "\r"

        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [iconBg, title, nameLabel, detail, buttons])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 8
        col.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        col.translatesAutoresizingMaskIntoConstraints = false
        col.setCustomSpacing(12, after: iconBg)
        col.setCustomSpacing(14, after: detail)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        sheet.contentView = content
        content.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: content.topAnchor),
            col.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detail.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -48),
            buttons.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -48),
        ])
    }

    func beginAsSheet(of window: NSWindow) {
        if let content = sheet.contentView {
            content.layoutSubtreeIfNeeded()
            let st = content.subviews.compactMap { $0 as? NSStackView }.first
            let contentH = st?.fittingSize.height ?? content.fittingSize.height
            if contentH > 80 {
                let h = min(contentH + 2, 400)
                var f = sheet.frame
                f.origin.y += f.height - h
                f.size.height = h
                sheet.setFrame(f, display: false)
            }
        }
        window.beginSheet(sheet) { [self] _ in onClose?() }
    }

    @objc private func cancelTapped(_ sender: Any?) {
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func cancel(_ sender: Any?) {
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func confirmTapped(_ sender: Any?) {
        sheet.sheetParent?.endSheet(sheet)
        onConfirm?()
    }
}

// MARK: - 文字垂直居中的单行输入框
// NSTextField 默认把文字画在 cell 顶部/基线，这里重写 drawingRect 让其垂直居中
final class VerticallyCenteredTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
    }
    convenience init() {
        self.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override class var cellClass: AnyClass? {
        get { VerticallyCenteredCell.self }
        set {}
    }
}

final class VerticallyCenteredCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textH = font?.pointSize ?? 12
        let lineH = ceil(textH * 1.35)
        let y = rect.minY + (rect.height - lineH) / 2
        return NSRect(x: rect.minX, y: y, width: rect.width, height: lineH)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?, start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView,
                     editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}
