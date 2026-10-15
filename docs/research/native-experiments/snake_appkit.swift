// A ~200 line AppKit snake game, the kind of code an agent would generate for the native path.
import AppKit
import QuartzCore

final class SnakeView: NSView {
    struct P: Hashable { var x: Int; var y: Int }
    let cell: CGFloat = 24
    var snake: [P] = [P(x: 5, y: 5), P(x: 4, y: 5), P(x: 3, y: 5)]
    var dir = P(x: 1, y: 0), nextDir = P(x: 1, y: 0)
    var food = P(x: 10, y: 8)
    var score = 0
    var scene = "start"
    var acc: CFTimeInterval = 0
    var last: CFTimeInterval = CACurrentMediaTime()
    var link: CADisplayLink?

    override var acceptsFirstResponder: Bool { true }
    var cols: Int { max(1, Int(bounds.width / cell)) }
    var rows: Int { max(1, Int(bounds.height / cell)) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        link = displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        window?.makeFirstResponder(self)
    }

    @objc func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime(); let dt = min(0.1, now - last); last = now
        if scene == "play" { acc += dt; while acc > 0.12 && scene == "play" { acc -= 0.12; step() } }
        needsDisplay = true
    }

    func reset() {
        snake = [P(x: 5, y: 5), P(x: 4, y: 5), P(x: 3, y: 5)]
        dir = P(x: 1, y: 0); nextDir = dir; score = 0; placeFood()
    }

    func placeFood() { food = P(x: Int.random(in: 0..<cols), y: Int.random(in: 0..<rows)) }

    func step() {
        dir = nextDir
        let h = P(x: (snake[0].x + dir.x + cols) % cols, y: (snake[0].y + dir.y + rows) % rows)
        if snake.contains(h) { scene = "over"; return }
        snake.insert(h, at: 0)
        if h == food { score += 10; placeFood() } else { snake.removeLast() }
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49, 36: if scene != "play" { reset(); scene = "play" }
        case 126: turn(P(x: 0, y: 1))
        case 125: turn(P(x: 0, y: -1))
        case 123: turn(P(x: -1, y: 0))
        case 124: turn(P(x: 1, y: 0))
        default: super.keyDown(with: e)
        }
    }

    func turn(_ d: P) { if scene == "play" && (d.x != -dir.x || d.y != -dir.y) { nextDir = d } }

    override func draw(_ r: NSRect) {
        NSColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1).setFill(); bounds.fill()
        NSColor.systemPink.setFill()
        NSBezierPath(ovalIn: NSRect(x: CGFloat(food.x) * cell + 4, y: CGFloat(food.y) * cell + 4, width: cell - 8, height: cell - 8)).fill()
        for (i, s) in snake.enumerated() {
            (i == 0 ? NSColor.systemGreen : NSColor.systemGreen.withAlphaComponent(0.75)).setFill()
            NSRect(x: CGFloat(s.x) * cell + 2, y: CGFloat(s.y) * cell + 2, width: cell - 4, height: cell - 4).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
        ("得分 \(score)" as NSString).draw(at: NSPoint(x: 16, y: bounds.height - 32), withAttributes: attrs)
        if scene != "play" {
            let t = (scene == "over" ? "游戏结束 · 按空格重来" : "贪吃蛇 · 按空格开始") as NSString
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.white]
            let sz = t.size(withAttributes: big)
            t.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: bounds.height / 2), withAttributes: big)
        }
    }
}

/// Entry point the host looks up with dlsym.
@_cdecl("agentos_make_view")
public func agentosMakeView() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SnakeView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))).toOpaque()
}
