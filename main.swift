import Foundation
import Virtualization
import AppKit


// Configs

struct VMConfig: Codable {
    var cpuCount: Int
    var memorySizeGB: Double
    var sharedDirectories: [SharedDirectory]?

    init(cpuCount: Int, memoryGB: Double) {
        self.cpuCount = cpuCount
        self.memorySizeGB = memoryGB
    }

    init(fromURL url: URL) throws {
        self = try JSONDecoder().decode(VMConfig.self, from: Data(contentsOf: url))
    }

    func save(toURL url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    struct SharedDirectory: Codable {
        var hostPath: String
        var tag: String
        var readOnly: Bool = false
    }
}

// VM Directory Structure

struct VMDirectory {
    let baseURL: URL
    var configURL: URL { baseURL.appendingPathComponent("config.json") }
    var diskURL: URL { baseURL.appendingPathComponent("disk.img") }
    var nvramURL: URL { baseURL.appendingPathComponent("nvram.bin") }
    var lockURL: URL { baseURL.appendingPathComponent(".lock") }

    var exists: Bool { FileManager.default.fileExists(atPath: baseURL.path) }

    var isInitialized: Bool {
        [configURL, diskURL, nvramURL].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    func create() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func createDisk(sizeGB: UInt16) throws {
        guard FileManager.default.createFile(atPath: diskURL.path, contents: nil) else {
            throw VMError("Failed to create disk image at \(diskURL.path)")
        }
        let handle = try FileHandle(forWritingTo: diskURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sizeGB) * 1_000_000_000)
    }

    // Acquire an exclusive lock. Returns file descriptor that must stay open.
    // Ensures that each VM can only be launched once by mini-vz, to prevent corrupting disk
    func acquireLock() throws -> Int32 {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw VMError("Cannot create lock file: \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw VMError("VM '\(baseURL.lastPathComponent)' is already running")
        }
        return fd
    }

    func createNVRAM() throws {
        _ = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
    }
}

// Terminal Raw Mode
// Raw mode disables line buffering, echo, and special character handling (Ctrl+C, etc.)
// so every keystroke passes straight through to the VM's serial console.

private var originalTermios: termios?          // Global: must survive independently for atexit handler

func enableRawMode() {
    guard isatty(STDIN_FILENO) != 0 else { return }
    var saved = termios()
    tcgetattr(STDIN_FILENO, &saved)            // Read current terminal settings
    originalTermios = saved                    // Stash a copy for restoration
    var raw = saved
    cfmakeraw(&raw)                            // Modify copy to raw mode
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)     // Apply raw settings immediately
    atexit { restoreTerminal() }               // Ensure terminal is restored on exit
}

func restoreTerminal() {
    if var t = originalTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &t)   // Restore original terminal settings
        originalTermios = nil                  // Clear so we don't restore twice
    }
}

// Helper Functions

struct VMError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = "Error: \(msg)" }
}

func expandPath(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

// Parse "path:ro" syntax into (path, readOnly)
func parsePathWithRO(_ arg: String) -> (path: String, readOnly: Bool) {
    if arg.hasSuffix(":ro") {
        return (String(arg.dropLast(3)), true)
    }
    return (arg, false)
}

func makeDiskAttachment(path: String) throws -> VZStorageDeviceConfiguration {
    let (rawPath, explicitRO) = parsePathWithRO(path)
    let expanded = expandPath(rawPath)
    let url = URL(fileURLWithPath: expanded)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw VMError("Disk not found: \(expanded)")
    }
    let readOnly = explicitRO || expanded.lowercased().hasSuffix(".iso")
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: url, readOnly: readOnly,
        cachingMode: .cached,
        synchronizationMode: readOnly ? .none : .full
    )
    return VZVirtioBlockDeviceConfiguration(attachment: attachment)
}

// VM Class

class LinuxVM: NSObject, VZVirtualMachineDelegate {
    let virtualMachine: VZVirtualMachine
    let config: VMConfig
    let vmDir: VMDirectory
    let headless: Bool
    let useSerial: Bool
    private let lockFd: Int32

    // Kept for startup display
    let displayCpuCount: Int
    let displayMemoryGB: Double
    let displayDisks: [(name: String, readOnly: Bool)]
    let displayShares: [(path: String, tag: String, readOnly: Bool)]

    init(vmDir: VMDirectory, diskPaths: [String] = [], headless: Bool = false,
         useSerial: Bool = false, cpuOverride: Int? = nil,
         memoryGBOverride: Double? = nil, sharePaths: [String] = []) throws {
        self.vmDir = vmDir
        self.headless = headless
        self.useSerial = useSerial

        guard vmDir.isInitialized else {
            throw VMError("VM not found at \(vmDir.baseURL.path)")
        }

        self.lockFd = try vmDir.acquireLock()
        self.config = try VMConfig(fromURL: vmDir.configURL)

        let cpuCount = cpuOverride ?? config.cpuCount
        let memoryGB = memoryGBOverride ?? config.memorySizeGB
        self.displayCpuCount = cpuCount
        self.displayMemoryGB = memoryGB

        // Build shares list from config + runtime args
        var shares: [(path: String, tag: String, readOnly: Bool)] = []
        for s in config.sharedDirectories ?? [] {
            shares.append((s.hostPath, s.tag, s.readOnly))
        }
        let base = shares.count
        for (i, arg) in sharePaths.enumerated() {
            let (path, ro) = parsePathWithRO(arg)
            shares.append((path, "share\(base + i)", ro))
        }
        let tags = shares.map { $0.tag }
        if Set(tags).count != tags.count { throw VMError("Duplicate share tags detected — rename tags in config.json to avoid conflicts") }
        self.displayShares = shares

        // Build disk info for display
        self.displayDisks = diskPaths.map { path in
            let (raw, ro) = parsePathWithRO(path)
            let isISO = raw.lowercased().hasSuffix(".iso")
            return (URL(fileURLWithPath: expandPath(raw)).lastPathComponent, ro || isISO)
        }

        // --- Build VZ configuration ---
        let vz = VZVirtualMachineConfiguration()

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: vmDir.nvramURL)
        vz.bootLoader = bootLoader
        vz.platform = VZGenericPlatformConfiguration()

        vz.cpuCount = min(max(cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        // Round ram to nearest Mebibyte (required by Virtualization.Framework)
        let mb: UInt64 = 1_048_576
        let memBytes = (UInt64(memoryGB * 1_000_000_000) + mb - 1) / mb * mb
        vz.memorySize = min(max(memBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // Storage: root disk + additional disks
        let rootAttachment = try VZDiskImageStorageDeviceAttachment(
            url: vmDir.diskURL, readOnly: false,
            cachingMode: .cached, synchronizationMode: .full
        )
        vz.storageDevices = try [VZVirtioBlockDeviceConfiguration(attachment: rootAttachment)]
            + diskPaths.map { try makeDiskAttachment(path: $0) }

        // Network (NAT)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        vz.networkDevices = [net]

        // Serial console
        if headless && useSerial {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: .standardInput, fileHandleForWriting: .standardOutput)
            vz.serialPorts = [serial]
        }

        // Graphics, input, clipboard
        if headless {
            vz.graphicsDevices = []
            vz.keyboards = []
            vz.pointingDevices = []
        } else {
            let gpu = VZVirtioGraphicsDeviceConfiguration()
            gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: 1024, heightInPixels: 768)]
            vz.graphicsDevices = [gpu]
            vz.keyboards = [VZUSBKeyboardConfiguration()]
            vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

            // Clipboard via Spice agent
            let console = VZVirtioConsoleDeviceConfiguration()
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            let spice = VZSpiceAgentPortAttachment()
            spice.sharesClipboard = true
            port.attachment = spice
            console.ports[0] = port
            vz.consoleDevices.append(console)
        }

        // Audio
        let sound = VZVirtioSoundDeviceConfiguration()
        if headless {
            sound.streams = [VZVirtioSoundDeviceOutputStreamConfiguration()]
        } else {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            output.sink = VZHostAudioOutputStreamSink()
            sound.streams = [input, output]
        }
        vz.audioDevices = [sound]

        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Shared directories (virtio-fs)
        vz.directorySharingDevices = try shares.map { share in
            let url = URL(fileURLWithPath: expandPath(share.path))
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw VMError("Shared path is not a directory: \(share.path)")
            }
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: url, readOnly: share.readOnly))
            return fs
        }

        try vz.validate()
        self.virtualMachine = VZVirtualMachine(configuration: vz)
        super.init()
        self.virtualMachine.delegate = self
    }

    @MainActor
    func start() async throws {
        let mode = headless ? (useSerial ? "headless+serial" : "headless") : "GUI"
        print("Starting Linux VM (\(mode) mode)...")
        print("  VM: \(vmDir.baseURL.path)")
        print("  CPU: \(displayCpuCount) cores, Memory: \(displayMemoryGB) GB")
        if !headless { print("  Display: 1024x768") }
        for d in displayDisks { print("  Disk: \(d.name) (\(d.readOnly ? "ro" : "rw"))") }
        for s in displayShares { print("  Share: \(s.path) (\(s.readOnly ? "ro" : "rw")) -> mount -t virtiofs \(s.tag) /mnt") }
        if headless && useSerial {
            print("\n  Serial console attached.")
            print("  (Note: Guest must have serial console enabled, e.g., 'console=ttyAMA0' on ARM)")
        }
        print("")

        if useSerial { enableRawMode() }
        try await virtualMachine.start()
        if !(headless && useSerial) { print("VM started successfully") }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        restoreTerminal()
        print("\nGuest stopped")
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        restoreTerminal()
        print("\nVM stopped with error: \(error)")
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
}

// App Delegate (GUI mode)

class AppDelegate: NSObject, NSApplicationDelegate {
    var vm: LinuxVM!
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Linux VM: \(vm.vmDir.baseURL.lastPathComponent)"
        window.center()

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = vm.virtualMachine
        vmView.capturesSystemKeys = true
        if #available(macOS 14.0, *) { vmView.automaticallyReconfiguresDisplay = true }
        vmView.frame = window.contentView!.bounds
        vmView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(vmView)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task {
            do {
                try await vm.start()
                window.makeFirstResponder(vmView)
            } catch {
                print("Failed to start VM: \(error)")
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard vm.virtualMachine.state == .running else { return .terminateNow }
        print("Stopping VM...")
        Task { @MainActor in
            try? await vm.virtualMachine.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// Argument Parsing

func parseArgs(_ args: [String]) -> (positional: String?, flags: [String: String], lists: [String: [String]], bools: Set<String>) {
    var positional: String?
    var flags: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var bools: Set<String> = []
    let valueFlags: Set<String> = ["--disk-size", "--cpus", "--ram", "--disk", "--share"]
    let listFlags: Set<String> = ["--disk", "--share"]
    let boolFlags: Set<String> = ["--headless", "--serial", "--background", "--help"]

    var i = 0
    while i < args.count {
        let arg = args[i]
        if valueFlags.contains(arg) {
            guard i + 1 < args.count else {
                print("Error: \(arg) requires a value. Run mini-vz --help for usage."); exit(1)
            }
            if listFlags.contains(arg) {
                lists[arg, default: []].append(args[i + 1])
            } else {
                flags[arg] = args[i + 1]
            }
            i += 2
        } else if boolFlags.contains(arg) {
            bools.insert(arg)
            i += 1
        } else if positional == nil {
            positional = arg
            i += 1
        } else {
            print("Error: Unknown argument: \(arg). Run mini-vz --help for usage."); exit(1)
        }
    }
    return (positional, flags, lists, bools)
}

func printUsage() {
    let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print("""
    Usage: \(name) <command> [options]

    A standalone Linux VM tool using Apple's Virtualization.framework

    Commands:
      create <vm-path>    Create a new Linux VM
      run <vm-path>       Run an existing Linux VM

    Create Options:
      --disk-size <GB>    Disk size in gigabytes (default: 50)
      --cpus <count>      Number of CPU cores (default: 4)
      --ram <GB>          Memory in gigabytes (default: 4, supports decimals)

    Run Options:
      --cpus <count>      Override CPU cores for this session
      --ram <GB>          Override memory for this session
      --share <path[:ro]> Share a host directory (append :ro for read-only)
      --headless          Run without GUI
      --serial            Attach serial console to terminal (implies --headless)
      --background        Run headless in background (detached from terminal)
      --disk <path[:ro]>  Attach additional disk (ISO files default to read-only)

    Examples:
      \(name) create ./VM_Directory --disk-size 30
      \(name) run ./VM_Directory --disk ~/Downloads/ubuntu-24.04-arm64.iso
      \(name) run ./VM_Directory --headless
      \(name) run ./VM_Directory --serial
      \(name) run ./VM_Directory --background
    """)
}

// Command Implementations

func runCreate(vmPath: String, diskSizeGB: UInt16, cpuCount: Int, memoryGB: Double) throws {
    let path = expandPath(vmPath)
    let vmDir = VMDirectory(baseURL: URL(fileURLWithPath: path))

    guard !vmDir.isInitialized else { throw VMError("VM already exists at \(path)") }

    print("Creating Linux VM...")
    print("  Path: \(path), Disk: \(diskSizeGB) GB, CPU: \(cpuCount) cores, Memory: \(memoryGB) GB\n")

    try vmDir.create()
    try vmDir.createNVRAM()
    try vmDir.createDisk(sizeGB: diskSizeGB)

    let config = VMConfig(cpuCount: cpuCount, memoryGB: memoryGB)
    try config.save(toURL: vmDir.configURL)

    print("VM created successfully!\n")
    print("Next steps:")
    print("  1. Download a Linux ARM64 ISO (e.g., Ubuntu Server for ARM)")
    print("  2. Boot with ISO: ./mini-vz run \(vmPath) --disk /path/to/linux.iso")
    print("  3. After installation, run without ISO: ./mini-vz run \(vmPath)")
}

func runVM(vmPath: String, headless: Bool, serial: Bool, background: Bool,
           diskPaths: [String], cpuCount: Int?, memoryGB: Double?, sharePaths: [String]) throws {
    let path = expandPath(vmPath)
    let vmDir = VMDirectory(baseURL: URL(fileURLWithPath: path))

    guard vmDir.isInitialized else { throw VMError("VM not found at \(path)") }

    // Handle --background: re-launch detached and exit
    if background {
        // Check lock before spawning to give immediate feedback
        let fd = open(vmDir.lockURL.path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                close(fd)
                throw VMError("VM '\(vmDir.baseURL.lastPathComponent)' is already running")
            }
            flock(fd, LOCK_UN)
            close(fd)
        }


        var bgArgs = ["run", vmPath, "--headless"]
        if let cpu = cpuCount { bgArgs += ["--cpus", String(cpu)] }
        if let mem = memoryGB { bgArgs += ["--ram", String(mem)] }
        for d in diskPaths { bgArgs += ["--disk", d] }
        for s in sharePaths { bgArgs += ["--share", s] }

        // Launch mini-vz in a background process and report pid
        let execPath = CommandLine.arguments[0]
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))

        // Redirect stdin/stdout/stderr to /dev/null
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let argv = ([execPath] + bgArgs).map { strdup($0) } + [nil]
        let rc = posix_spawnp(&pid, execPath, &fileActions, &attrs, argv, environ)
        argv.compactMap { $0 }.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attrs)

        guard rc == 0 else { throw VMError("Failed to spawn background process: \(String(cString: strerror(rc)))") }

        let name = vmDir.baseURL.lastPathComponent
        print("VM '\(name)' started in background (PID: \(pid))")
        print("To stop: kill \(pid), or ssh into VM and send shutdown signal")
        print("To find: ps aux | grep '\(name)'")
        return
    }

    let vm = try LinuxVM(vmDir: vmDir, diskPaths: diskPaths, headless: headless,
                         useSerial: serial, cpuOverride: cpuCount,
                         memoryGBOverride: memoryGB, sharePaths: sharePaths)

    
    // Handle SIGINT (if process is killed when --serial is being used, will restore terminal. Otherwise need to run "reset" to restore it)
    let stopHandler: () -> Void = {
        Task { @MainActor in
            restoreTerminal()
            print("\nStopping VM...")
            try? await vm.virtualMachine.stop()
            exit(0)
        }
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM)
    sigintSource.setEventHandler(handler: stopHandler)
    sigtermSource.setEventHandler(handler: stopHandler)
    sigintSource.activate()
    sigtermSource.activate()

    if headless {
        Task {
            do { try await vm.start() }
            catch { print("Failed to start VM: \(error)"); exit(1) }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    } else {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        delegate.vm = vm
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

// Main

let args = Array(CommandLine.arguments.dropFirst())
let subcommand = args.first ?? "help"

do {
    switch subcommand {
    case "create":
        let p = parseArgs(Array(args.dropFirst()))
        guard let vmPath = p.positional, !p.bools.contains("--help") else { printUsage(); exit(0) }
        let diskSize = p.flags["--disk-size"].flatMap { UInt16($0) } ?? 50
        let cpu = p.flags["--cpus"].flatMap { Int($0) } ?? 4
        let mem = p.flags["--ram"].flatMap { Double($0) } ?? 4
        try runCreate(vmPath: vmPath, diskSizeGB: diskSize, cpuCount: cpu, memoryGB: mem)

    case "run":
        let p = parseArgs(Array(args.dropFirst()))
        guard let vmPath = p.positional, !p.bools.contains("--help") else { printUsage(); exit(0) }
        let serial = p.bools.contains("--serial")
        let background = p.bools.contains("--background")
        let headless = p.bools.contains("--headless") || serial || background
        try runVM(vmPath: vmPath, headless: headless, serial: serial, background: background,
                  diskPaths: p.lists["--disk"] ?? [], cpuCount: p.flags["--cpus"].flatMap { Int($0) },
                  memoryGB: p.flags["--ram"].flatMap { Double($0) }, sharePaths: p.lists["--share"] ?? [])

    case "help", "--help", "-h":
        printUsage()

    default:
        print("Unknown command: \(subcommand). Run mini-vz --help for usage.")
        exit(1)
    }
} catch {
    print("\(error)")
    exit(1)
}
