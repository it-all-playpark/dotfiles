// uc-edge-probe — Universal Control の「エッジ押し込み」が
// 合成 CGEvent で発火するかを確かめるプローブ。
//
//   swift uc-edge-probe.swift                 # 下調べのみ（カーソルを動かさない）
//   swift uc-edge-probe.swift --edge right    # 右端へ押し込む
//   swift uc-edge-probe.swift --edge right --duration 2500 --delta 12
//
// 実行するターミナルに「アクセシビリティ」権限が要る。
// 権限が無いと AXIsProcessTrusted = false になり、post しても何も起きない。

import Foundation
import CoreGraphics
import ApplicationServices

// ---- 引数 ----------------------------------------------------------------

let argv = CommandLine.arguments

func flag(_ name: String) -> String? {
  guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
  return argv[i + 1]
}

let edge = flag("--edge")                                  // right / left / top / bottom
let durationMs = Int(flag("--duration") ?? "2500") ?? 2500
let delta = Double(flag("--delta") ?? "8") ?? 8            // 1 イベントあたりの押し込み量
let hz = 120.0

// ---- 下調べ --------------------------------------------------------------

func cursor() -> CGPoint {
  CGEvent(source: nil)?.location ?? CGPoint(x: CGFloat.nan, y: CGFloat.nan)
}

func sh(_ cmd: String) -> String {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", cmd]
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = pipe
  try? p.run()
  let d = pipe.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return String(data: d, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

print("== session ==")
let manager = sh("launchctl managername")
print("launchctl managername = \(manager)   <- Aqua でないと TCC は効かない")
let ssh = ProcessInfo.processInfo.environment["SSH_CONNECTION"] ?? ""
print("SSH_CONNECTION        = \(ssh.isEmpty ? "(none)" : ssh)")
print("process ancestry (TCC はこの祖先のどれかに紐づく):")
print(sh("""
  pid=\(getpid())
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    ps -o pid=,comm= -p "$pid" | sed 's/^/  /'
    pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  done
"""))

if manager != "Aqua" || !ssh.isEmpty {
  print("""

  !! このシェルは Aqua セッションではない（mosh / ssh / 別ドメインの zellij サーバー配下）。
     TCC はここに権限を紐付けられないので、合成イベントは post できない。
     Mac Studio 実機で開いた ghostty から、zellij の外で実行すること。
  """)
  exit(2)
}

print("\n== preflight ==")
print("AXIsProcessTrusted = \(AXIsProcessTrusted())")

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
print("active displays  = \(n)")

var union = CGRect.null
for i in 0..<Int(n) {
  let b = CGDisplayBounds(ids[i])
  union = union.union(b)
  let main = CGDisplayIsMain(ids[i]) != 0 ? " (main)" : ""
  print(String(format: "  #%u  x=%.0f y=%.0f w=%.0f h=%.0f%@",
               ids[i], b.origin.x, b.origin.y, b.width, b.height, main))
}
print(String(format: "union bounds     = x=%.0f y=%.0f w=%.0f h=%.0f",
             union.origin.x, union.origin.y, union.width, union.height))
print("cursor           = \(cursor())")

if n == 0 {
  print("\n!! WindowServer に接続できていない。GUI セッションのターミナルから実行すること。")
  exit(2)
}
guard let edge else {
  print("\n下調べのみ完了。押し込むなら --edge right|left|top|bottom を付けて再実行。")
  print("MacBook Pro が配置上どちら側かを上の bounds で確認してから選ぶこと。")
  exit(0)
}
if !AXIsProcessTrusted() {
  print("\n!! アクセシビリティ権限が無い。システム設定 → プライバシーとセキュリティ →")
  print("   アクセシビリティ でこのターミナルを許可してから再実行すること。")
  exit(2)
}

// ---- 押し込み ------------------------------------------------------------

// 押し込む先の一歩手前（対象エッジの中央から 2px 内側）を始点にする
let inset = 2.0
var start = CGPoint(x: union.midX, y: union.midY)
var step = CGPoint(x: 0, y: 0)

switch edge {
case "right":
  start = CGPoint(x: union.maxX - inset, y: union.midY)
  step = CGPoint(x: delta, y: 0)
case "left":
  start = CGPoint(x: union.minX + inset, y: union.midY)
  step = CGPoint(x: -delta, y: 0)
case "bottom":
  start = CGPoint(x: union.midX, y: union.maxY - inset)
  step = CGPoint(x: 0, y: delta)
case "top":
  start = CGPoint(x: union.midX, y: union.minY + inset)
  step = CGPoint(x: 0, y: -delta)
default:
  print("--edge は right / left / top / bottom のいずれか")
  exit(64)
}

let origin = cursor()
print("\n== push (\(edge), \(durationMs)ms, delta=\(delta)/event) ==")
print("origin cursor = \(origin)")

let src = CGEventSource(stateID: .hidSystemState)

func postMove(to p: CGPoint, dx: Double, dy: Double) {
  guard let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                        mouseCursorPosition: p, mouseButton: .left) else { return }
  // エッジ検出は絶対座標ではなく delta を見ている可能性が高いので必ず載せる
  e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
  e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
  e.post(tap: .cghidEventTap)
}

// 観測の準備。押し込みが始まったら MBP 側を見ていてほしい
for i in stride(from: 3, through: 1, by: -1) {
  print("  MacBook Pro の画面を見てください … \(i)")
  usleep(1_000_000)
}

// まずエッジ手前へ寄せる
postMove(to: start, dx: 0, dy: 0)
usleep(150_000)
print("at edge       = \(cursor())")

// エッジの外へ押し続ける
let frames = max(1, Int(Double(durationMs) / 1000.0 * hz))
let interval = UInt32(1_000_000.0 / hz)
var target = start
var trace: [CGPoint] = []

for i in 0..<frames {
  target = CGPoint(x: target.x + step.x, y: target.y + step.y)
  postMove(to: target, dx: step.x, dy: step.y)
  if i % 20 == 0 { trace.append(cursor()) }
  usleep(interval)
}

// 移っていた場合に見る時間を作る（ここで戻すと一瞬で消えて判定できない）
usleep(2_000_000)

let after = cursor()
print("cursor trace  = \(trace.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " "))")
print("cursor after  = \(after)")

// ---- 判定 ----------------------------------------------------------------

print("\n== result ==")
print("ローカルのカーソル座標だけでは «相手機に移った» と «端で止まった» を区別できない。")
print("MacBook Pro の画面を見て、ポインタが出現したかどうかで判定すること。")
print("")
print("  出現した  -> 合成イベントで Universal Control が発火する（案1 成立）")
print("  出現しない -> 発火しない（案2 のフォールバックへ）")
print("")
print("同時にログを見るなら別ターミナルで:")
print("  log stream --style compact --predicate 'process == \"UniversalControl\"'")

// 移らなかった場合に備えてカーソルを戻す
postMove(to: origin, dx: 0, dy: 0)
