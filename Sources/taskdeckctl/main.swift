import Darwin
import Foundation
import TaskDeckCore

// taskdeckctl — headless debug/scripting client for taskdeckd.

let rawArgs = Array(CommandLine.arguments.dropFirst())

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

func flag(_ name: String) -> String? {
    guard let i = rawArgs.firstIndex(of: name), i + 1 < rawArgs.count else { return nil }
    return rawArgs[i + 1]
}

guard let cmd = rawArgs.first else {
    die("""
    usage: taskdeckctl <command>
      ping
      list
      new <taskID> [--title t] [--cwd path] [--cmd 'command']
      type <paneID> <text...>       # sends text + newline
      tail <paneID> [seconds]       # replay ring buffer, stream output
      resize <paneID> <cols> <rows>
      kill <paneID>
      remove <paneID>
      shutdown                      # DANGER: kills every live session
    """)
}

guard let conn = BlockingConn() else {
    die("cannot connect to taskdeckd at \(Wire.socketPath()) (daemon not running?)")
}

switch cmd {
case "ping":
    var m = WireMessage(type: "ping")
    m.version = Wire.version
    print(conn.request(m)?.type ?? "no reply")

case "list":
    let r = conn.request(WireMessage(type: "list"))
    guard let panes = r?.panes else { die("no reply") }
    if panes.isEmpty { print("(no panes)") }
    for p in panes.sorted(by: { $0.taskID < $1.taskID }) {
        let state = p.running ? "run " : "exit(\(p.exitCode.map(String.init) ?? "?"))"
        print("\(p.id)  \(state)  \(p.taskID)/\(p.title)  \(p.cols)x\(p.rows)  \(p.cwd)")
    }

case "new":
    guard rawArgs.count > 1 else { die("new <taskID> [--title t] [--cwd path] [--cmd c]") }
    var m = WireMessage(type: "newPane")
    m.taskID = rawArgs[1]
    m.specID = UUID().uuidString
    m.title = flag("--title") ?? "ctl"
    m.cwd = flag("--cwd") ?? FileManager.default.currentDirectoryPath
    m.command = flag("--cmd")
    m.cols = 100
    m.rows = 28
    let r = conn.request(m)
    if let pid = r?.paneID { print(pid) } else { die("error: \(r?.message ?? "no reply")") }

case "type":
    guard rawArgs.count > 2 else { die("type <paneID> <text...>") }
    var m = WireMessage(type: "input")
    m.paneID = rawArgs[1]
    m.setData(Array((rawArgs.dropFirst(2).joined(separator: " ") + "\n").utf8))
    conn.send(m)
    usleep(100_000)

case "tail":
    guard rawArgs.count > 1 else { die("tail <paneID> [seconds]") }
    let secs = rawArgs.count > 2 ? (Double(rawArgs[2]) ?? 3) : 3
    var sub = WireMessage(type: "subscribe")
    sub.paneID = rawArgs[1]
    guard let first = conn.request(sub) else { die("no reply") }
    if first.type == "error" { die("error: \(first.message ?? "?")") }
    if let bytes = first.dataBytes { FileHandle.standardOutput.write(Data(bytes)) }
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(conn.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let deadline = Date().addingTimeInterval(secs)
    while Date() < deadline {
        guard let m = conn.recv() else { continue }
        if m.type == "output", m.paneID == rawArgs[1], let bytes = m.dataBytes {
            FileHandle.standardOutput.write(Data(bytes))
        }
    }
    print("")

case "resize":
    guard rawArgs.count > 3, let c = Int(rawArgs[2]), let r = Int(rawArgs[3]) else { die("resize <paneID> <cols> <rows>") }
    var m = WireMessage(type: "resize")
    m.paneID = rawArgs[1]
    m.cols = c
    m.rows = r
    conn.send(m)
    usleep(50_000)

case "kill", "remove":
    guard rawArgs.count > 1 else { die("\(cmd) <paneID>") }
    var m = WireMessage(type: cmd)
    m.paneID = rawArgs[1]
    print(conn.request(m)?.type ?? "no reply")

case "shutdown":
    print(conn.request(WireMessage(type: "shutdown"))?.type ?? "no reply")

default:
    die("unknown command: \(cmd)")
}
