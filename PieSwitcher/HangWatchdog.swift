import Darwin
import Foundation
import os

/// The Swift runtime's demangler. It has no Swift declaration, so bind it at runtime;
/// `RTLD_DEFAULT` (-2) searches every loaded image, and the Swift runtime is always one of
/// them. `nil` degrades symbolication to mangled names rather than failing.
private typealias SwiftDemangleFn = @convention(c) (
    UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
) -> UnsafeMutablePointer<CChar>?

private let swiftDemangle: SwiftDemangleFn? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else {
        return nil
    }
    return unsafeBitCast(symbol, to: SwiftDemangleFn.self)
}()

/// Watches the main run loop from a dedicated thread and, when a single pass overruns,
/// records what the main thread is stuck in — the named step in flight plus its call
/// stack — to the unified log.
///
/// A stall here is not merely a slow wheel: the activation event tap is an active
/// `.cgSessionEventTap` whose callback runs on this run loop, so for as long as the main
/// thread is busy the window server is waiting on us and the pointer stops moving. That
/// makes "which step blocked, and in what call" the only question worth answering, and it
/// has to be answered from the outside — a blocked thread cannot report on itself.
///
/// Read the findings with:
/// `log show --info --last 30m --predicate 'subsystem == "com.mekedron.PieSwitcher" AND category == "hang"'`
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    private static let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "hang")

    /// A run-loop pass longer than this is long enough for the user to feel the pointer
    /// hitch, so it is worth a stack. Well above an ordinary summon's frame of work.
    private static let threshold: TimeInterval = 0.06
    /// How often the watchdog thread checks the current pass. Fine enough to catch a stall
    /// near its start, coarse enough to be free.
    private static let pollInterval: TimeInterval = 0.02
    /// While a stall persists, re-sample this often: a hang that moves through several calls
    /// shows as several stacks, and one that sits still repeats the same stack.
    private static let resampleInterval: TimeInterval = 0.5
    /// Stacks per stall, so a multi-second hang can't flood the log.
    private static let maxSamples = 5
    /// Frames per stack. Deep enough to cross SwiftUI/AppKit into our own frames.
    private static let maxFrames = 40

    private let lock = NSLock()
    /// When the run-loop pass currently being served began. Zero while the loop is idle.
    private var passStart: CFAbsoluteTime = 0
    private var isBusy = false
    private var samplesThisPass = 0
    private var lastSample: CFAbsoluteTime = 0
    private var stallID = 0

    /// The main thread's mach port, resolved at `start`, so the watchdog can read its
    /// register state without going through the (blocked) thread itself.
    private var mainMachThread: thread_t = 0
    private var observer: CFRunLoopObserver?

    /// Begin watching. Call once, from the main thread, at launch.
    func start() {
        guard observer == nil else { return }
        mainMachThread = pthread_mach_thread_np(pthread_self())
        installRunLoopObserver()
        let thread = Thread { [weak self] in
            while let self {
                self.tick()
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }
        thread.name = "com.mekedron.PieSwitcher.hang-watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        Self.log.info("hang watchdog armed (threshold \(Int(Self.threshold * 1000))ms)")
    }

    // MARK: - Run-loop pass tracking

    /// Mark where each run-loop pass starts and ends. The activities that precede work
    /// (`afterWaiting`, `beforeTimers`, `beforeSources`) open a pass; `beforeWaiting` closes
    /// it, which is what distinguishes a blocked main thread from an idle one — an idle loop
    /// sits in `beforeWaiting` indefinitely and must never be reported.
    private func installRunLoopObserver() {
        let activities: CFRunLoopActivity = [
            .entry, .beforeTimers, .beforeSources, .afterWaiting, .beforeWaiting, .exit
        ]
        observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities.rawValue, true, 0
        ) { [weak self] _, activity in
            guard let self else { return }
            if activity == .beforeWaiting || activity == .exit {
                self.endPass()
            } else {
                self.beginPass()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func beginPass() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        passStart = now
        isBusy = true
        samplesThisPass = 0
        lastSample = 0
        lock.unlock()
    }

    private func endPass() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let stalled = samplesThisPass > 0
        let elapsed = now - passStart
        let identifier = stallID
        isBusy = false
        samplesThisPass = 0
        lock.unlock()
        guard stalled else { return }
        let milliseconds = String(format: "%.0f", elapsed * 1000)
        Self.log.info("hang#\(identifier, privacy: .public) ended after \(milliseconds, privacy: .public)ms")
    }

    // MARK: - Sampling

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let busy = isBusy
        let elapsed = now - passStart
        let sampled = samplesThisPass
        let sinceLast = now - lastSample
        var identifier = stallID
        var shouldSample = false
        if busy, elapsed > Self.threshold, sampled < Self.maxSamples,
           sampled == 0 || sinceLast > Self.resampleInterval {
            if sampled == 0 {
                stallID += 1
                identifier = stallID
            }
            samplesThisPass += 1
            lastSample = now
            shouldSample = true
        }
        lock.unlock()
        guard shouldSample else { return }
        report(identifier: identifier, elapsed: elapsed, sample: sampled + 1)
    }

    private func report(identifier: Int, elapsed: TimeInterval, sample: Int) {
        // Read the breadcrumb before suspending: it is guarded by a lock the main thread
        // takes, and a lock must never be contended against a thread that cannot run.
        let step = SlowStep.breadcrumb
        let frames = captureMainThreadStack()
        let milliseconds = String(format: "%.0f", elapsed * 1000)
        Self.log.info("""
            hang#\(identifier, privacy: .public) sample \(sample, privacy: .public): \
            main thread blocked \(milliseconds, privacy: .public)ms in [\(step, privacy: .public)]
            """)
        for (index, frame) in frames.enumerated() {
            Self.log.info("hang#\(identifier, privacy: .public)   \(index, privacy: .public) \(frame, privacy: .public)")
        }
    }

    /// The main thread's call stack, symbolicated.
    ///
    /// The frames are walked by hand rather than with `backtrace_from_fp`, which validates
    /// frames against the *calling* thread's stack bounds and so answers about the watchdog
    /// instead of its subject. Walking the saved-frame-pointer chain works because both
    /// threads share one address space: each frame stores the previous frame pointer at
    /// `[fp]` and its return address at `[fp + 8]`.
    ///
    /// The thread stays suspended only for the register read and that walk, neither of which
    /// allocates — symbolication runs after it is resumed. Suspending across an allocation
    /// would deadlock the instant the blocked thread happened to hold the malloc lock, which
    /// is one of the states this code exists to catch.
    private func captureMainThreadStack() -> [String] {
        guard thread_suspend(mainMachThread) == KERN_SUCCESS else {
            return ["<could not suspend main thread>"]
        }
        var addresses: [UInt] = []
        if let (pc, fp) = mainThreadRegisters() {
            addresses.reserveCapacity(Self.maxFrames)
            addresses.append(pc)
            var frame = fp
            while addresses.count < Self.maxFrames {
                // A frame pointer is 16-byte aligned and always higher up the stack than the
                // frame it links from; anything else means the chain has run off the end (or
                // into a frameless leaf), and following it further would read noise.
                guard frame != 0, frame % 16 == 0,
                      let next: UInt = readWord(at: frame),
                      let returnAddress: UInt = readWord(at: frame + 8),
                      returnAddress != 0, next > frame else { break }
                addresses.append(returnAddress)
                frame = next
            }
        }
        thread_resume(mainMachThread)

        guard !addresses.isEmpty else { return ["<could not read main thread state>"] }
        return symbolicate(addresses)
    }

    /// One machine word from this process's address space, or `nil` when the address is not
    /// readable. Read through `vm_read_overwrite` rather than dereferenced, so a frame chain
    /// that has gone astray returns an error instead of taking the app down with it.
    private func readWord(at address: UInt) -> UInt? {
        var value: UInt = 0
        var read: vm_size_t = 0
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            vm_read_overwrite(
                mach_task_self_,
                vm_address_t(address),
                vm_size_t(MemoryLayout<UInt>.size),
                vm_address_t(UInt(bitPattern: pointer)),
                &read
            )
        }
        guard result == KERN_SUCCESS, read == vm_size_t(MemoryLayout<UInt>.size) else { return nil }
        return value
    }

    /// The main thread's program counter and frame pointer, read from its register state.
    private func mainThreadRegisters() -> (pc: UInt, fp: UInt)? {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainMachThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt(state.__pc), UInt(state.__fp))
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainMachThread, x86_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt(state.__rip), UInt(state.__rbp))
        #else
        return nil
        #endif
    }

    /// Turn return addresses into `<image> <symbol> + <offset>` lines, demangling Swift names
    /// so the log reads as source rather than as mangled symbols.
    private func symbolicate(_ addresses: [UInt]) -> [String] {
        addresses.map { address in
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: address),
                  dladdr(pointer, &info) != 0, let name = info.dli_sname else {
                return String(format: "0x%016lx", address)
            }
            let image = info.dli_fname.map {
                (String(cString: $0) as NSString).lastPathComponent
            } ?? "?"
            let offset = address - UInt(bitPattern: info.dli_saddr)
            return "\(image) \(Self.demangled(String(cString: name))) + \(offset)"
        }
    }

    /// The human-readable form of a Swift symbol, via the runtime's own demangler; C symbols
    /// and anything it declines to parse come back unchanged.
    private static func demangled(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s"), let demangle = swiftDemangle else {
            return symbol
        }
        var length = 0
        guard let buffer = demangle(symbol, symbol.utf8.count, nil, &length, 0) else {
            return symbol
        }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}
