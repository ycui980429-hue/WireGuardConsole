// PowerButton.swift — 大圆形电源按钮 + 卡片视图
import AppKit

// MARK: - 大圆形电源按钮（实心圆 + 电源符号，参考图样式）
final class PowerButton: NSView {
    enum Mode { case disconnected, connecting, connected, failed }

    var mode: Mode = .disconnected {
        didSet {
            if mode == .connecting { startSpinning() } else { stopSpinning() }
            needsDisplay = true
        }
    }
    var onTap: (() -> Void)?
    private var spinAngle: CGFloat = 0
    private var timer: Timer?
    private var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 150) }
    override var acceptsFirstResponder: Bool { true }

    func startSpinning() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinAngle = (self.spinAngle + 7).truncatingRemainder(dividingBy: 360)
            self.needsDisplay = true
        }
    }
    func stopSpinning() { timer?.invalidate(); timer = nil }

    // 各状态的填充色与前景色
    private var discFill: NSColor {
        switch mode {
        case .disconnected: return NSColor(red: 0.945, green: 0.953, blue: 0.961, alpha: 1)  // 浅灰
        case .connecting:   return NSColor(red: 0.996, green: 0.945, blue: 0.878, alpha: 1)  // 浅橙
        case .connected:    return NSColor(red: 0.122, green: 0.702, blue: 0.337, alpha: 1)  // 绿 #1fb356
        case .failed:       return NSColor(red: 0.996, green: 0.925, blue: 0.910, alpha: 1)  // 浅红
        }
    }
    private var iconColor: NSColor {
        switch mode {
        case .disconnected: return NSColor(red: 0.545, green: 0.588, blue: 0.635, alpha: 1)  // 中灰
        case .connecting:   return NSColor(red: 0.902, green: 0.549, blue: 0.047, alpha: 1)  // 橙
        case .connected:    return .white
        case .failed:       return NSColor(red: 0.827, green: 0.271, blue: 0.227, alpha: 1)  // 红
        }
    }
    private var ringColor: NSColor {
        switch mode {
        case .disconnected: return NSColor(red: 0.878, green: 0.894, blue: 0.910, alpha: 1)
        case .connecting:   return NSColor(red: 0.949, green: 0.588, blue: 0.086, alpha: 1)
        case .connected:    return NSColor(red: 0.122, green: 0.702, blue: 0.337, alpha: 1)
        case .failed:       return NSColor(red: 0.827, green: 0.271, blue: 0.227, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 8

        // 连接成功的柔和光晕
        if mode == .connected {
            for (i, alpha) in [(6.0, 0.10), (12.0, 0.06), (18.0, 0.035)] {
                let r = radius + CGFloat(i)
                ringColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r,
                                            width: r * 2, height: r * 2)).fill()
            }
        }

        // 实心圆
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        discFill.setFill()
        disc.fill()
        if mode == .disconnected || hovered {
            ringColor.setStroke()
            disc.lineWidth = 1
            disc.stroke()
        }

        // 连接中：外圈旋转弧（在圆外一点点，不压住图标）
        if mode == .connecting {
            let arcR = radius + 5
            let path = NSBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            let startDeg = spinAngle
            path.appendArc(withCenter: center, radius: arcR,
                           startAngle: startDeg, endAngle: startDeg + 90)
            ringColor.setStroke()
            path.stroke()
        }

        // 中心电源符号：圆圈留顶部缺口 + 竖线
        let iconR = radius * 0.42
        iconColor.setStroke()

        // 圆弧：从 52° 顺时针到 128°，缺口正对顶部
        let arc = NSBezierPath()
        arc.lineWidth = max(iconR * 0.20, 3.0)
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: center, radius: iconR,
                      startAngle: 52, endAngle: 128, clockwise: true)
        arc.stroke()

        // 竖线：从圆心上方穿过缺口延伸到圆内
        let line = NSBezierPath()
        line.lineWidth = max(iconR * 0.20, 3.0)
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: center.x, y: center.y + iconR * 1.42))
        line.line(to: NSPoint(x: center.x, y: center.y + iconR * 0.10))
        line.stroke()
    }

    // 鼠标交互
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - 卡片容器
final class CardView: NSView {
    var fill: NSColor = Theme.card {
        didSet { needsDisplay = true }
    }
    var borderColor: NSColor = Theme.cardBorder {
        didSet { needsDisplay = true }
    }
    var radius: CGFloat = 12 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // 浅色主题：白卡片需要极轻的投影才有层次
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.05
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - 通用小工具
func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
           color: NSColor = .secondaryLabelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    return l
}

// MARK: - 下拉箭头按钮（标准 chevron.down 造型，描边线条）
final class ArrowButton: NSButton {
    private var hovering = false
    /// 展开下拉时置 true，箭头翻转朝上
    var expanded = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
    }
    convenience init(target: AnyObject?, action: Selector?) {
        self.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // hover 圆形浅底
        if hovering {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            Theme.accent.withAlphaComponent(0.10).setFill()
            circle.fill()
        }

        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let color = hovering ? Theme.accent : Theme.muted
        color.setStroke()

        // 标准下拉 chevron ∨：两条等长斜线，圆头圆角
        // 注意 NSButton 的绘制坐标系是翻转的（y 向下），dir 需要取反才是视觉上的 ∨
        let halfW: CGFloat = 4.6
        let halfH: CGFloat = 2.6
        let dir: CGFloat = isFlipped ? -1 : 1

        let path = NSBezierPath()
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: c.x - halfW, y: c.y + dir * halfH))
        path.line(to: NSPoint(x: c.x, y: c.y - dir * halfH))
        path.line(to: NSPoint(x: c.x + halfW, y: c.y + dir * halfH))
        path.stroke()
    }
}

// MARK: - 可点击高亮的行（供下拉浮层使用）
final class HoverRow: NSView {
    var onTap: (() -> Void)?
    var pendingViews: (name: NSTextField, sub: NSTextField, check: NSImageView)?
    private var hovering = false
    private var isSelectedRow = false

    override func layout() {
        super.layout()
        guard let v = pendingViews else { return }
        let h = bounds.height
        let checkW: CGFloat = 16
        let textW = bounds.width - 20 - checkW - 8

        v.name.frame = NSRect(x: 10, y: h / 2 + 1, width: textW, height: 16)
        v.sub.frame = NSRect(x: 10, y: h / 2 - 17, width: textW, height: 14)
        v.check.frame = NSRect(x: bounds.width - checkW - 10, y: (h - 14) / 2,
                               width: checkW, height: 14)
    }

    func setSelected(_ on: Bool) {
        isSelectedRow = on
        layer?.backgroundColor = on
            ? Theme.accent.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if !isSelectedRow {
            layer?.backgroundColor = Theme.accent.withAlphaComponent(0.06).cgColor
        }
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !isSelectedRow {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - 窗口内下拉浮层
// 全部用 frame 手动布局：NSStackView/NSScrollView 作为 documentView 时宽度依赖
// Auto Layout 时序，容易算出 0 宽导致行不可点击。
final class DropdownOverlay: NSView {
    private let dim = NSView()
    private let card = NSView()
    private let rowClip = NSView()
    private let rowScroll = NSScrollView()
    private var rows: [HoverRow] = []
    private var onDismiss: (() -> Void)?

    static let rowH: CGFloat = 50
    static let padV: CGFloat = 6
    static let padH: CGFloat = 6

    init(items: [(title: String, subtitle: String, selected: Bool)],
         width: CGFloat,
         onPick: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.cardBorder.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.18
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = CGSize(width: 0, height: -5)
        card.autoresizingMask = []
        addSubview(card)

        // 行放在滚动视图里：配置多、高度不够时可以滚动，
        // 而不是把超出的行直接隐藏（那样后排永远选不到）
        rowScroll.drawsBackground = false
        rowScroll.hasVerticalScroller = true
        rowScroll.autohidesScrollers = true
        rowScroll.borderType = .noBorder
        rowScroll.scrollerStyle = .overlay
        rowScroll.autoresizingMask = []
        rowClip.wantsLayer = true
        rowScroll.documentView = rowClip
        card.addSubview(rowScroll)

        // 逐行创建（frame 布局）
        for item in items {
            let row = HoverRow()
            row.wantsLayer = true
            row.layer?.cornerRadius = 8
            row.setSelected(item.selected)

            let name = label(item.title, size: 12,
                             weight: item.selected ? .semibold : .regular,
                             color: item.selected ? Theme.accent : Theme.text)
            name.font = .monospacedSystemFont(ofSize: 12,
                                              weight: item.selected ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingMiddle

            let sub = label(item.subtitle, size: 12, color: Theme.faint)
            sub.lineBreakMode = .byTruncatingMiddle

            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.contentTintColor = Theme.accent
            check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            check.isHidden = !item.selected

            row.subviews.forEach { $0.removeFromSuperview() }
            row.addSubview(name)
            row.addSubview(sub)
            row.addSubview(check)
            row.pendingViews = (name: name, sub: sub, check: check)

            row.onTap = { [weak self] in
                onPick(item.title)
                self?.dismiss()
            }
            rowClip.addSubview(row)
            rows.append(row)
        }
        self.itemWidth = width
    }
    required init?(coder: NSCoder) { fatalError() }

    private var itemWidth: CGFloat = 260

    /// 内容自然高度（不含窗口限制）
    private var contentHeight: CGFloat {
        CGFloat(rows.count) * Self.rowH + Self.padV * 2
    }

    /// 在锚点矩形附近弹出，始终限制在 host 内
    func present(in host: NSView, anchorRect: NSRect) {
        frame = host.bounds
        dim.frame = bounds
        host.addSubview(self, positioned: .above, relativeTo: nil)

        // 宽度：与锚点对齐，但不超出窗口
        let w = max(min(anchorRect.width, host.bounds.width - 16), 220)
        // 高度上限：留出上下各 40pt
        let maxH = host.bounds.height - 80
        let h = min(contentHeight, maxH)

        // 垂直：下方够就下方，否则上方，最后 clamp
        let spaceBelow = anchorRect.minY - 10
        let spaceAbove = host.bounds.height - anchorRect.maxY - 10
        var y: CGFloat
        if spaceBelow >= h + 8 {
            y = anchorRect.minY - h - 6
        } else if spaceAbove >= h + 8 {
            y = anchorRect.maxY + 6
        } else {
            y = (spaceBelow > spaceAbove) ? anchorRect.minY - h - 6 : anchorRect.maxY + 6
        }
        y = max(10, min(y, host.bounds.height - h - 10))
        var x = anchorRect.minX
        x = max(8, min(x, host.bounds.width - w - 8))

        card.frame = NSRect(x: x, y: y, width: w, height: h)
        layoutRows()
    }

    private func layoutRows() {
        // 可视区域（扣掉内边距）交给滚动视图，内容再高也能滚到
        let viewH = max(card.bounds.height - Self.padV * 2, Self.rowH)
        rowScroll.frame = NSRect(x: Self.padH, y: Self.padV,
                                 width: card.bounds.width - Self.padH * 2,
                                 height: viewH)
        let docH = max(CGFloat(rows.count) * Self.rowH, viewH)
        rowClip.frame = NSRect(x: 0, y: 0,
                               width: rowScroll.contentView.bounds.width, height: docH)

        let w = rowClip.bounds.width
        let startTop = docH - Self.padV
        for (i, row) in rows.enumerated() {
            let rowY = startTop - CGFloat(i + 1) * Self.rowH
            row.frame = NSRect(x: 0, y: rowY, width: w, height: Self.rowH)
            row.isHidden = false
            row.layout()
        }
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
        layoutRows()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { dismiss() }
    }

    func dismiss() {
        removeFromSuperview()
        onDismiss?()
    }
}

