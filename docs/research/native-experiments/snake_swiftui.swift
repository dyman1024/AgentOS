// The same game written with SwiftUI + Canvas + TimelineView, which LLMs tend to produce for "native" requests.
import SwiftUI
import AppKit

@Observable final class Game {
    struct P: Hashable { var x: Int; var y: Int }
    var snake: [P] = [P(x: 5, y: 5), P(x: 4, y: 5), P(x: 3, y: 5)]
    var dir = P(x: 1, y: 0)
    var food = P(x: 10, y: 8)
    var score = 0
    var scene = "start"
    var cols = 26
    var rows = 20
    var acc: Double = 0
    var last: Date = .now

    func update(_ now: Date) {
        let dt = min(0.1, now.timeIntervalSince(last)); last = now
        guard scene == "play" else { return }
        acc += dt
        while acc > 0.12 && scene == "play" { acc -= 0.12; step() }
    }
    func step() {
        let h = P(x: (snake[0].x + dir.x + cols) % cols, y: (snake[0].y + dir.y + rows) % rows)
        if snake.contains(h) { scene = "over"; return }
        snake.insert(h, at: 0)
        if h == food { score += 10; food = P(x: Int.random(in: 0..<cols), y: Int.random(in: 0..<rows)) } else { snake.removeLast() }
    }
    func key(_ k: KeyEquivalent) {
        switch k {
        case .space, .return: if scene != "play" { snake = [P(x: 5, y: 5), P(x: 4, y: 5), P(x: 3, y: 5)]; dir = P(x: 1, y: 0); score = 0; scene = "play" }
        case .upArrow: if dir.y == 0 { dir = P(x: 0, y: -1) }
        case .downArrow: if dir.y == 0 { dir = P(x: 0, y: 1) }
        case .leftArrow: if dir.x == 0 { dir = P(x: -1, y: 0) }
        case .rightArrow: if dir.x == 0 { dir = P(x: 1, y: 0) }
        default: break
        }
    }
}

struct SnakeGameView: View {
    @State private var game = Game()
    @FocusState private var focused: Bool
    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let c = min(size.width / CGFloat(game.cols), size.height / CGFloat(game.rows))
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.06, green: 0.08, blue: 0.11)))
                g.fill(Path(ellipseIn: CGRect(x: CGFloat(game.food.x) * c + 4, y: CGFloat(game.food.y) * c + 4, width: c - 8, height: c - 8)), with: .color(.pink))
                for (i, s) in game.snake.enumerated() {
                    g.fill(Path(CGRect(x: CGFloat(s.x) * c + 2, y: CGFloat(s.y) * c + 2, width: c - 4, height: c - 4)), with: .color(i == 0 ? .green : .green.opacity(0.75)))
                }
                g.draw(Text("得分 \(game.score)").font(.headline).foregroundStyle(.white), at: CGPoint(x: 60, y: 20))
                if game.scene != "play" {
                    g.draw(Text(game.scene == "over" ? "游戏结束 · 按空格重来" : "贪吃蛇 · 按空格开始").font(.title.bold()).foregroundStyle(.white), at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            }
            .onChange(of: ctx.date) { _, d in game.update(d) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress { press in game.key(press.key); return .handled }
        .onAppear { focused = true }
    }
}

@_cdecl("agentos_make_view")
public func agentosMakeView() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(NSHostingView(rootView: SnakeGameView())).toOpaque()
}
