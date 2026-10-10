import Dispatch
import Foundation
import RemoteClientCore
import RemoteProtocol
import RemoteServerCore

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    let names = Command.allCases.map(\.name).joined(separator: ", ")
    print("""
    remotectl — test harness for the Mac side of the remote

      remotectl keytest [COMMAND] [--delay SECONDS]
          Post a key press to whichever app is in front. Needs Accessibility.
          Default COMMAND is RIGHT, default delay is 3 seconds so you can
          switch to the app you want to test against.

      remotectl swipe left|right|up|down [--delay SECONDS]
          Post the shortcut a three-finger swipe sends (Ctrl+arrow). Needs
          Accessibility. Default delay is 1 second.

      remotectl serve [--allow-new]
          Advertise over Bluetooth and press keys for approved devices.
          --allow-new approves whatever connects, for testing.

      remotectl send COMMAND [COMMAND ...]
          Find the Mac and send taps. Stands in for the iPhone.

    COMMAND is one of: \(names)
    """)
    exit(1)
}

func parseCommand(_ raw: String) -> Command {
    guard let command = Command(name: raw) else {
        print("unknown command '\(raw)'")
        usage()
    }
    return command
}

func requireAccessibility() {
    guard !KeyInjector.isTrusted else { return }
    print("""
    This process cannot post key events yet.

    Allow MacRemote in System Settings → Privacy & Security → Accessibility,
    then run this again.
    """)
    KeyInjector.requestTrust()
    exit(1)
}

/// macOS drops synthetic events from a binary with no stable code identity, and it
/// does so silently, so catch it here rather than letting key presses vanish.
func requireBundledApp() {
    guard Bundle.main.bundleIdentifier == nil else { return }
    print("""
    Refusing to run: this is the bare executable, and macOS will silently drop
    every key press it posts. Use the bundled app instead:

      ./scripts/make-app.sh
      ./.build/MacRemote.app/Contents/MacOS/MacRemote \(arguments.joined(separator: " "))
    """)
    exit(1)
}

switch arguments.first {
case "keytest":
    requireBundledApp()
    requireAccessibility()

    var rest = Array(arguments.dropFirst())
    var delay: TimeInterval = 3
    if let flag = rest.firstIndex(of: "--delay"), rest.indices.contains(flag + 1) {
        delay = TimeInterval(rest[flag + 1]) ?? 3
        rest.removeSubrange(flag...(flag + 1))
    }
    let command = rest.first.map(parseCommand) ?? .right

    print("pressing \(command.name) in \(Int(delay))s — switch to the app you want to test")
    Thread.sleep(forTimeInterval: delay)
    KeyInjector().tap(command)
    print("sent")

case "swipe":
    requireBundledApp()
    requireAccessibility()

    var rest = Array(arguments.dropFirst())
    var delay: TimeInterval = 1
    if let flag = rest.firstIndex(of: "--delay"), rest.indices.contains(flag + 1) {
        delay = TimeInterval(rest[flag + 1]) ?? 1
        rest.removeSubrange(flag...(flag + 1))
    }
    let directions: [String: SwipeDirection] = ["left": .left, "right": .right, "up": .up, "down": .down]
    guard let name = rest.first, let direction = directions[name.lowercased()] else { usage() }

    Thread.sleep(forTimeInterval: delay)
    KeyInjector().switchSpace(direction)
    print("swiped \(name)")

case "serve":
    requireBundledApp()
    if !KeyInjector.isTrusted {
        print("warning: no Accessibility permission, key presses will be silently dropped")
        KeyInjector.requestTrust()
    }

    let allowNew = arguments.contains("--allow-new")
    let server = RemoteServer()
    server.onStatus = { status in
        switch status {
        case .advertising:
            print("advertising over Bluetooth as \"\(RemoteService.defaultName)\"")
        case .poweredOff:
            print("Bluetooth is off — turn it on to advertise")
        case .unauthorized:
            print("no Bluetooth permission: allow it in System Settings → Privacy & Security → Bluetooth")
            exit(1)
        case .unsupported:
            print("this Mac does not support Bluetooth LE")
            exit(1)
        case .failed(let message):
            print("failed: \(message)")
            exit(1)
        case .stopped:
            print("stopped")
        }
    }
    server.onDevices = { devices in
        for device in devices {
            let approval = device.isApproved ? "approved" : "waiting"
            let link = device.isConnected ? "connected" : "offline"
            print("device: \(device.name) (\(device.shortID)) — \(approval), \(link)")
        }
        for device in devices where !device.isApproved && allowNew {
            print("approving \(device.name) (\(device.shortID))")
            server.approve(device.id)
        }
    }
    server.onEvent = { event in
        print("\(event.command.name) \(event.isDown ? "down" : "up")")
    }
    server.start()
    // Not dispatchMain(): that parks the real main thread, so main-queue callbacks
    // would run on a worker and trip the main-actor checks.
    RunLoop.main.run()

case "send":
    let commands = arguments.dropFirst().map(parseCommand)
    guard !commands.isEmpty else { usage() }

    let client = RemoteClient()
    var hasSent = false

    client.onStatus = { status in
        switch status {
        case .scanning:
            print("scanning…")
        case .connecting(let name):
            print("connecting to \(name)…")
        case .securing(let name):
            print("securing connection to \(name)…")
        case .failed(let message):
            print(message)
            exit(1)
        case .awaitingApproval(let name):
            print("waiting for \(name) to allow this device…")
        case .connected(let name):
            guard !hasSent else { return }
            hasSent = true
            print("connected to \(name)")
            for command in commands {
                client.tap(command)
                print("sent \(command.name)")
            }
            // Give the writes a moment to drain before dropping the link.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                client.stop()
                exit(0)
            }
        case .poweredOff:
            print("Bluetooth is off")
        case .unauthorized:
            print("no Bluetooth permission")
            exit(1)
        case .unsupported:
            print("this Mac does not support Bluetooth LE")
            exit(1)
        case .stopped:
            break
        }
    }
    client.start()

    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        guard !hasSent else { return }
        print("gave up: no Mac found nearby")
        exit(1)
    }
    RunLoop.main.run()

default:
    usage()
}
