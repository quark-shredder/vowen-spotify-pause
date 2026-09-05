// vowen-spotify-pause — pause Spotify while Vowen is dictating, resume when it stops.
//
// Event-driven, zero idle cost:
//   • CoreAudio property listener on the input device fires the start/stop edges
//     (Vowen's recorder only runs the mic while dictating).
//   • One GET /v1/status to Vowen's local API per start edge confirms it is Vowen
//     on the mic and not some other app.
//   • kqueue NOTE_EXIT on Vowen's pid ends this process the instant Vowen quits.
//   • Spotify is driven with raw Apple Events (codes from `sdef Spotify.app`),
//     addressed by pid — no AppleScript runtime in-process, no osascript spawn,
//     and Spotify can never be launched by accident.
// Only resumes playback it paused itself, so it never starts music you stopped on purpose.

import CoreAudio
import Foundation

setbuf(stdout, nil)

let serverJSON = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Vowen/cli/server.json")

let stamp = DateFormatter()
stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
func log(_ message: String) { print("[\(stamp.string(from: Date()))] \(message)") }

// MARK: - Spotify via raw Apple Events

func code(_ s: String) -> OSType { s.utf8.reduce(0) { $0 << 8 | OSType($1) } }

/// pid of the running Spotify main process, via sysctl so we never need AppKit.
func spotifyPID() -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return nil }
    for i in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
        var comm = procs[i].kp_proc.p_comm
        let capacity = MemoryLayout.size(ofValue: comm)
        let name = withUnsafePointer(to: &comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        if name == "Spotify" { return procs[i].kp_proc.p_pid }
    }
    return nil
}

func spotifyEvent(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor? {
    guard let pid = spotifyPID() else { return nil }
    return NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID),
                                  targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                  returnID: AEReturnID(kAutoGenerateReturnID),
                                  transactionID: AETransactionID(kAnyTransactionID))
}

func send(_ event: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
    do {
        return try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
    } catch {
        log("Apple Event failed: \(error.localizedDescription)")
        return nil
    }
}

/// `get player state of application "Spotify"`, by hand. nil if Spotify isn't running or didn't answer.
func spotifyIsPlaying() -> Bool? {
    guard let event = spotifyEvent("core", "getd") else { return nil }
    let specifier = NSAppleEventDescriptor.record()
    specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
    specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
    specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code("pPlS")), forKeyword: code("seld"))
    specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
    guard let object = specifier.coerce(toDescriptorType: code("obj ")) else { return nil }
    event.setParam(object, forKeyword: keyDirectObject)
    guard let reply = send(event), let state = reply.paramDescriptor(forKeyword: keyDirectObject) else { return nil }
    return state.enumCodeValue == code("kPSP")
}

func spotifyPause() -> Bool { spotifyEvent("spfy", "Paus").flatMap(send) != nil }
func spotifyPlay()  -> Bool { spotifyEvent("spfy", "Play").flatMap(send) != nil }

if CommandLine.arguments.contains("--check") {
    let started = Date()
    let playing = spotifyIsPlaying()
    let ms = Date().timeIntervalSince(started) * 1000
    print(playing.map { "Spotify is \($0 ? "playing" : "not playing")" } ?? "Spotify not running or no reply",
          String(format: "(%.1f ms round trip)", ms))
    exit(0)
}

// MARK: - Vowen

struct Server { let port: UInt16; let token: String; let pid: pid_t }

func readServer() -> Server? {
    guard let data = try? Data(contentsOf: serverJSON),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = json["port"] as? Int, let token = json["token"] as? String, let pid = json["pid"] as? Int
    else { return nil }
    return Server(port: UInt16(port), token: token, pid: pid_t(pid))
}

func processIsAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Startup only: Vowen rewrites server.json a moment after launch, so tolerate a short race.
func waitForServer() -> Server? {
    for _ in 0..<30 {
        if let server = readServer(), processIsAlive(server.pid) { return server }
        usleep(500_000)
    }
    return nil
}

/// One GET /v1/status over a throwaway localhost socket. nil on any failure, 401 included.
func vowenIsRecording(_ server: Server) -> Bool? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = server.port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }

    let request = "GET /v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        + "Authorization: Bearer \(server.token)\r\nConnection: close\r\n\r\n"
    guard request.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }

    var chunk = [UInt8](repeating: 0, count: 4096)
    var response = [UInt8]()
    while true {
        let n = recv(fd, &chunk, chunk.count, 0)
        if n <= 0 { break }
        response.append(contentsOf: chunk[0..<n])
    }
    guard let text = String(bytes: response, encoding: .utf8), text.hasPrefix("HTTP/1.1 200") else { return nil }
    return text.contains("\"recording\":true")
}

guard var server = waitForServer() else {
    log("Vowen is not running, nothing to watch")
    exit(0)
}

// MARK: - State (everything below runs on the main queue)

var micRunning = false
var pausedByUs = false

func confirmAndPause(attempt: Int) {
    guard micRunning, !pausedByUs else { return }
    var recording = vowenIsRecording(server)
    if recording == nil, let fresh = readServer() {   // token rotates on every Vowen start
        server = fresh
        recording = vowenIsRecording(server)
    }
    if recording == true {
        let started = Date()
        if spotifyIsPlaying() == true, spotifyPause() {
            pausedByUs = true
            log(String(format: "dictation started, Spotify paused (%.0f ms)", Date().timeIntervalSince(started) * 1000))
        }
    } else if attempt == 0 {
        // Mic can come up a beat before Vowen flips its flag; look once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { confirmAndPause(attempt: 1) }
    }
}

func resumeIfWePaused(_ reason: String) {
    guard pausedByUs else { return }
    pausedByUs = false
    _ = spotifyPlay()
    log(reason)
}

func micEdge(_ running: Bool) {
    guard running != micRunning else { return }
    micRunning = running
    if running {
        confirmAndPause(attempt: 0)
    } else {
        resumeIfWePaused("dictation ended, Spotify resumed")
    }
}

// MARK: - CoreAudio

func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultInputDevice() -> AudioDeviceID {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = property(kAudioHardwarePropertyDefaultInputDevice)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
}

func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = property(kAudioDevicePropertyDeviceIsRunningSomewhere)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
}

var device = defaultInputDevice()
var runningAddress = property(kAudioDevicePropertyDeviceIsRunningSomewhere)
var defaultAddress = property(kAudioHardwarePropertyDefaultInputDevice)
let audioQueue = DispatchQueue(label: "coreaudio")

let onRunningChanged: AudioObjectPropertyListenerBlock = { _, _ in
    DispatchQueue.main.async { micEdge(isRunningSomewhere(device)) }
}
AudioObjectAddPropertyListenerBlock(device, &runningAddress, audioQueue, onRunningChanged)

// Follow the default input if it changes (headset plugged in, AirPods connect).
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, audioQueue) { _, _ in
    DispatchQueue.main.async {
        let next = defaultInputDevice()
        guard next != device else { return }
        AudioObjectRemovePropertyListenerBlock(device, &runningAddress, audioQueue, onRunningChanged)
        device = next
        AudioObjectAddPropertyListenerBlock(device, &runningAddress, audioQueue, onRunningChanged)
        log("input device changed -> \(device)")
        micEdge(isRunningSomewhere(device))
    }
}

// MARK: - Lifecycle

let vowenExit = DispatchSource.makeProcessSource(identifier: server.pid, eventMask: .exit, queue: .main)
vowenExit.setEventHandler {
    resumeIfWePaused("Vowen quit mid-dictation, Spotify resumed")
    log("Vowen closed, exiting")
    exit(0)
}
vowenExit.resume()

signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler {
    resumeIfWePaused("terminated mid-dictation, Spotify resumed")
    log("terminated, exiting")
    exit(0)
}
terminate.resume()

log("watching Vowen (pid \(server.pid)) on input device \(device)")
micEdge(isRunningSomewhere(device))   // Vowen may already be mid-dictation when we start
RunLoop.main.run()
