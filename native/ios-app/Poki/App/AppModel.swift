import CryptoKit
import PokiCore
import SwiftUI
import UIKit
import UserNotifications

/// The app's state and the glue between PokiCore, PokiLauncher, the loopback, the Live Activity and
/// approvals. One instance, owned by PokiApp.
@MainActor
@Observable
final class AppModel {
    var setup = SetupState.load() { didSet { setup.save() } }
    let identity = RelayIdentity()
    /// The person's own relay (Connect). Poki has no default relay and sends nothing until one is set.
    private(set) var relayAddress = RelayAddress.saved
    /// The relay on or off (Agents > MCP Relay). On by default, and turned on when an address is set;
    /// off, Poki makes no relay connection and only its own chat agent can use the phone.
    private(set) var relayEnabled = UserDefaults.standard.object(forKey: "relayEnabled") as? Bool ?? true
    /// The relay Poki connects to: the address, while the relay is on.
    var activeRelay: RelayAddress? { relayEnabled ? relayAddress : nil }

    func setRelayEnabled(_ on: Bool) {
        guard on != relayEnabled, relayAddress != nil || !on else { return }
        relayEnabled = on
        UserDefaults.standard.set(on, forKey: "relayEnabled")
        log.add("relay", on ? "turned on" : "turned off")
        guard sessionOn else { return }
        if on, let relayAddress { core.start(relay: relayAddress) } else { core.stop() }
    }
    let loopback = LoopbackMonitor()
    let tunnel = LoopbackTunnel()
    let background = BackgroundKeeper()
    let diskImage = DiskImageStore()
    /// Poki keeps its own signing: the Apple Account, the next build ready ahead of time, Install.
    let signer = SelfSigner()
    let voice: VoiceModel
    private(set) var runner = RunnerStatus.idle
    private(set) var relayStatus = RelayStatus.off
    private(set) var sessionOn = false
    private(set) var activityText = "Idle"
    private(set) var lastAction: String?
    private(set) var approvals: [PendingApproval] = []
    private(set) var pairing: PairingEvent?
    private(set) var problem: String?
    /// The text the local connection last put in `problem` (another VPN is on), so only that is cleared.
    private var tunnelAttention: String?
    /// The agent's recent actions, newest last, for the home screen.
    private(set) var recentSteps: [RecentStep] = []
    /// The app the agent is in, from its last step.
    private(set) var currentApp: String?
    /// The runner is stopped until the next agent request (idle, or the owner tapped Stop runner).
    private(set) var runnerPaused = false
    /// Stop the runner after this long without agent activity; 0 never stops it.
    /// 60 s by default. An agent can think for about a minute between steps of a long task; after a
    /// longer pause the runner stops, and the agent's next request starts it again.
    /// In-process: close the automation session (and iOS's banner) when Poki stands by. Off by
    /// default until a session reopened in the same launch is shown to answer reads on the phone.
    var closeSessionWhenIdle: Bool = UserDefaults.standard.bool(forKey: "inProcess.closeWhenIdle") {
        didSet { UserDefaults.standard.set(closeSessionWhenIdle, forKey: "inProcess.closeWhenIdle"); log.add("runner", "close the session when idle: \(closeSessionWhenIdle ? "on" : "off")") }
    }
    /// Ask the owner before payments, deleting, sending, calls, passwords and Wallet input. On unless
    /// they turned it off; PokiCore reads it when Poki starts.
    var askBeforeSensitiveSteps: Bool = LiveCore.asksBeforeSensitiveSteps {
        didSet { UserDefaults.standard.set(askBeforeSensitiveSteps, forKey: LiveCore.askKey); log.add("approval", "ask before sensitive steps: \(askBeforeSensitiveSteps ? "on" : "off") (from the next start of Poki)") }
    }
    /// Approvals are decided by the chat model (ApprovalClassifier) instead of the owner. Testing only, off.
    var approvalClassifier: Bool = UserDefaults.standard.bool(forKey: ApprovalClassifier.onKey) {
        didSet { UserDefaults.standard.set(approvalClassifier, forKey: ApprovalClassifier.onKey); log.add("approval", "auto-classifier: \(approvalClassifier ? "on" : "off") (from the next start of Poki)") }
    }
    var classifierLevel: ApprovalClassifier.Level = ApprovalClassifier.Level.saved {
        didSet { UserDefaults.standard.set(classifierLevel.rawValue, forKey: ApprovalClassifier.levelKey); log.add("approval", "auto-classifier level: \(classifierLevel.rawValue)") }
    }
    /// Lists ask_poki for outside agents. Testing only, off.
    var askPokiTool: Bool = UserDefaults.standard.bool(forKey: AskPoki.onKey) {
        didSet { UserDefaults.standard.set(askPokiTool, forKey: AskPoki.onKey); log.add("chat", "ask_poki tool: \(askPokiTool ? "on" : "off")"); AskPoki.refresh() }
    }
    var idleStopSeconds: Int = UserDefaults.standard.object(forKey: "idleStopSeconds.v4") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(idleStopSeconds, forKey: "idleStopSeconds.v4"); log.add("runner", "idle stop set to \(idleStopSeconds) s") }
    }
    /// Poki was on when it last ran; it turns itself on again at launch. Poki Setup's install turns it
    /// on the first time (see `init`).
    private(set) var wantsOn: Bool {
        get { UserDefaults.standard.bool(forKey: "wantsOn") }
        set { UserDefaults.standard.set(newValue, forKey: "wantsOn") }
    }
    /// The setup step the Live Activity is guiding, if any.
    private(set) var guiding: SetupStep?
    /// The pairing file, if it is really there. The path is never stored: the app's container moves
    /// when Poki is installed again, and a stored path then points at nothing.
    var pairingPath: String? {
        _ = pairingFileSeen
        if FileManager.default.fileExists(atPath: AppFiles.phonePairingFile.path) { return AppFiles.phonePairingFile.path }
        return FileManager.default.fileExists(atPath: AppFiles.pairingFile.path) ? AppFiles.pairingFile.path : nil
    }
    /// Whether the pairing file was there at the last look. Poki Setup on a computer writes it into
    /// Poki's container after an install, while Poki may be running: setting this redraws what depends
    /// on `pairingPath` (the file itself is not observed).
    private var pairingFileSeen = FileManager.default.fileExists(atPath: AppFiles.pairingFile.path)
    /// Looks for a pairing file Poki Setup put in the container (at launch, on coming to the front,
    /// and every few seconds on the pairing step).
    func lookForHandedPairing() {
        let there = FileManager.default.fileExists(atPath: AppFiles.pairingFile.path)
        guard there != pairingFileSeen else { return }
        pairingFileSeen = there
        // A pairing made here writes the same file just before it reports `paired`, which handles it.
        guard there, !pairingUnderWay else { return }
        try? (AppFiles.pairingFile as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        setup.pairingFile = AppFiles.pairingFile.path
        SetupVault.mirrorPairingFromContainer()
        pairingTrouble = nil; pairingVerifiedAt = nil
        log.add("pairing", "pairing file from Poki Setup found")
    }
    /// Why the phone refused the pairing the last time the runner started, until it is accepted again.
    private(set) var pairingTrouble: String?
    /// When the phone last accepted the pairing (the runner got past the pairing step).
    private(set) var pairingVerifiedAt: Date?
    /// The loopback took the connection, but the phone's remote pairing service did not answer through
    /// it (GitHub issue 69). The loopback probe only connects, so it still reads Working; the
    /// Loopback page says so. false once the phone answers again.
    private(set) var servicesSilent = false
    /// The runner has been launching for a while: iOS may be asking for the passcode.
    private(set) var passcodeHint = false
    /// XCTest authorization is requested only when a real phone tool needs it. Native services
    /// and isolated-display tools do not use XCTest's authorization path.
    var passcodeExpected: Bool {
        automationPath != .nativeServices && UserDefaults.standard.double(forKey: Self.automationBootKey) != BootClock.current
    }
    private var automationRequested = false
    private static let automationBootKey = "automationStartedBoot"
    private func automationStarted() {
        InProcessWDA.gate.withLock { $0.startedThisBoot = true }
        UserDefaults.standard.set(BootClock.current, forKey: Self.automationBootKey)
    }
    func requestAutomationForTask(_ why: String) {
        guard automationPath == .inProcess else { return }
        automationRequested = true
        warmInProcess(why)
    }
    /// The hand-off the agent asked the owner for, while it waits (shown on the home screen too).
    private(set) var handoffText: String?
    private var launchingSince: Date?
    private var endCheck = 0
    /// Not set at launch: a fresh launch has run nothing, so Install is available at once.
    private var lastAgentActivity = Date.distantPast
    /// The last agent step (a tool call, a hand-off), for Install's wait. Turning on or waking the
    /// runner is not a step: lastAgentActivity counts those for the idle stop, this does not.
    private var lastStepAt = Date.distantPast
    /// The agent's step now running (its label and start), for the foreground check above.
    private var stepUnderWay: (summary: String, started: Date)?
    /// When the last approval ended, so a Stop landing on the Live Activity right after is not taken.
    private var lastApprovalAnswered: Date?
    private var idleTimer: Timer?
    private var launcherConfig: LauncherConfig?

    let host = AppCoreHost()
    /// Poki Runner or Poki's own process, fixed for this launch (Debug tab).
    let automationPath: AutomationPath
    private let core: LiveCore
    private let nativeServicesWDA: NativeServicesWDA?
    private let launcher: RunnerLauncher
    private let pairer: DevicePairing
    private let pairingKeepAlive = KeepAlive()
    private let activity = ActivityController()
    private var activityStop: (id: UUID, action: () -> Void)?
    var liveActivityState: PokiState { activity.state }

    func prepareAgentActivity() { activity.start(deviceName: deviceName) }

    func beginAgentActivity(_ id: UUID, background: Bool, stop: @escaping () -> Void) {
        activity.beginAgentTask(id, background: background)
        activity.start(deviceName: deviceName)
        activityStop = (id, stop)
    }
    func agentActivityPlan(_ id: UUID, steps: [String], current: Int) {
        activity.agentPlan(id, steps: steps.map { StepLabels.withoutTypedText($0) }, current: current)
    }
    func isolatedActivityStarted(_ id: UUID, title: String, app: String?) {
        guard activity.state.agentTask?.id == id, activity.state.agentTask?.active == true else { return }
        activity.stepStarted(title)
        activity.update { $0.phase = .working; $0.headline = title; $0.app = app ?? $0.app }
    }
    func isolatedActivityFinished(_ id: UUID, title: String, app: String?, answer: PokiCore.ToolAnswer) {
        guard activity.state.agentTask?.id == id, activity.state.agentTask?.active == true else { return }
        activity.record(step: title, ok: !answer.isError)
        activity.update { $0.app = app ?? $0.app }
        activity.setThumbnail(answer.jpeg)
    }
    func endAgentActivity(_ id: UUID, success: Bool?, stopped: Bool) {
        activity.endAgentTask(id, success: success, stopped: stopped)
        if activityStop?.id == id { activityStop = nil }
    }
    func stopAgentFromLiveActivity() {
        if let stop = activityStop?.action { stop() }
        else { pauseRunner(reason: "Stopped from the Live Activity") }
    }
    let log = AppLog.shared
    private var eventsTask: Task<Void, Never>?
    private var handoffTimer: Timer?
    private var sessionStartTask: Task<Void, Never>?
    private(set) var sessionStarting = false

    /// No task is running, so an install (which ends Poki) disturbs nothing: no agent step under way,
    /// no approval waiting, and a minute since the agent last did something.
    var signingIdle: Bool { signingBusyReason == nil }

    /// Why Install waits, or nil when nothing is under way. A step whose end never arrived (the
    /// session was turned off mid-step, or the call hung) stops counting after two minutes, so a
    /// lost event cannot keep Install off for good.
    var signingBusyReason: String? {
        if !approvals.isEmpty { return String(localized: "An approval is waiting for you.") }
        if sessionStarting { return String(localized: "Poki is turning on.") }
        if let step = stepUnderWay, sessionOn, Date().timeIntervalSince(step.started) < 120 {
            return String(localized: "The agent is doing a step: \(step.summary).")
        }
        let since = Date().timeIntervalSince(lastStepAt)
        if since < 60 { return String(localized: "The agent acted \(Int(since)) s ago; Install opens a minute after its last step.") }
        return nil
    }

    /// Hands the signer the phone's own services and starts it (at launch).
    func startSigner() {
        signer.phone = { [weak self] in
            guard let self, let path = self.pairingPath, self.loopback.isWorking else { return nil }
            return ["device_address": "10.7.0.1", "pairing_file": path, "host_name": "Poki"]
        }
        signer.isIdle = { [weak self] in self?.signingIdle ?? false }
        signer.busyReason = { [weak self] in self?.signingBusyReason }
        signer.beforeInstall = { [weak self] in self?.windDownForUpdate() }
        signer.start()
    }

    var connectionInUse: Bool {
        if sessionOn || sessionStarting { return true }
        return pairingUnderWay
    }

    var connectionMethod: SetupState.Loopback {
        if setup.loopback != .none { return setup.loopback }
        // The external app is the way (ESP-168); the built-in connection is only ever chosen.
        return .proxy
    }

    /// look, do or status run here as a relay call would be (the Debug probe's end-to-end check).
    /// The probe opened the in-process session itself (on the simulator there is no launcher), so
    /// PokiCore may act now.
    func inProcessReadyForProbe() { inProcessSession = .open; host.update(runner: .running); probeDriven = true }

    func phoneTool(_ name: String, arguments: String) async -> (text: String, isError: Bool) {
        let result = await core.tool(name, arguments: arguments)
        return (result.text, result.isError)
    }

    /// The same call with its picture, for the gym scorecard (the Debug probe's `gym` mode).
    func phoneToolWithPicture(_ name: String, arguments: String) async -> PokiCore.ToolAnswer {
        if name == "look" || name == "do" { requestAutomationForTask("a phone tool") }
        return await core.callTool(name, arguments: arguments)
    }

    /// The chats watch the steps and approvals of the task they run (the in-app chat and an outside
    /// agent's hand-off each have one).
    private var shellObservers: [(ShellEvent) -> Void] = []
    func addShellObserver(_ observer: @escaping (ShellEvent) -> Void) { shellObservers.append(observer) }
    /// A Debug probe drives PokiCore on the simulator without a runner session (the chat's end-to-end check).
    private(set) var probeDriven = false
    /// The app's MCP tools (ask_poki), set by AskPoki.
    func setHostTools(_ tools: [HostTool]) { core.setHostTools(tools) }
    /// The gym probe answers approvals itself: with no session on, `handle` keeps them off the screen.
    var onProbeApproval: ((PendingApproval) -> Void)?

    /// The outside agent driving the phone now: its MCP session's client, or the agent that handed
    /// a task to Poki. nil while Poki's own chat drives it.
    var currentCaller: String? {
        let store = SessionStore.shared
        if let id = store.activeSessionID, let client = store.session(id)?.client { return client }
        return ChatModel.delegatedBusy
    }

    init(launcher: RunnerLauncher = RustLauncher(), pairer: DevicePairing = RustPairing(), automation: InProcessAutomation = PKInProcess.shared(), automationPath: AutomationPath = .current) {
        self.automationPath = automationPath
        ActivityController.endAll()
        self.automation = automation
        // A reinstall emptied the container: the pairing file comes back from the Keychain (and the
        // setup state did the same in `SetupState.load`), so the owner is not sent through setup again.
        if SetupVault.restorePairingIfMissing() { AppLog.shared.add("pairing", "pairing file restored from the Keychain after a reinstall") }
        else { SetupVault.mirrorPairingFromContainer() }
        let transport: HTTPTransport
        switch automationPath {
        case .inProcess:
            nativeServicesWDA = nil
            transport = InProcessWDA(screen: UIScreen.main.bounds.size)
        case .nativeServices:
            let native = NativeServicesWDA(screen: UIScreen.main.bounds.size)
            nativeServicesWDA = native
            transport = native
        case .runner:
            nativeServicesWDA = nil
            transport = URLSessionTransport()
        }
        let core = LiveCore(host: host, transport: transport)
        self.core = core
        // Voice taps get the same rules and approval card as an agent's `do`.
        voice = VoiceModel(clearTap: { text, bundle, name in await core.clearTap(on: text, inApp: bundle, named: name, waiting: VoiceModel.approvalWait) },
                           phoneTool: { name, arguments in
                               let result = await core.tool(name, arguments: arguments)
                               return (result.text, result.isError)
                           },
                           holdMicrophone: { [background] on in on ? background.pauseAudio() : background.resumeAudio() })
        self.launcher = launcher
        self.pairer = pairer
        host.update(key: identity.signingKey, hashes: identity.accessHashes)
        host.onConsent { [weak self] client, callback, connector in
            await self?.askToConnect(client: client, callback: callback, connector: connector) ?? false
        }
        // PokiCore asks for a restart after two silent requests in a row. A slow gesture can be one of
        // them while the runner is fine, so the runner is asked first; only a runner that does not
        // answer is started again (each restart costs seconds and flashes the automation banner).
        host.onRestart { [weak self, automationPath] in
            // XCTest in-process has no runner to ask: its one session is kept.
            guard automationPath != .inProcess else {
                Task { @MainActor in
                    guard let self else { return }
                    // A reopened session reads nothing in this launch, so the one open is kept: its
                    // requests have deadlines of their own, and a busy app answers again by itself.
                    self.log.add("runner", "PokiCore asked for a restart: the in-process session is kept (a reopened one cannot read the screen in the same launch)")
                    self.warmInProcess("PokiCore's restart")
                }
                return
            }
            if automationPath == .nativeServices {
                Task { @MainActor [weak self] in
                    AppLog.shared.add("runner", "PokiCore asked for a restart: reopening the experimental native-services tunnel")
                    await self?.nativeServicesWDA?.reset()
                }
                return
            }
            Task.detached {
                let answers = await RunnerProbe.answers()
                await MainActor.run { AppLog.shared.add("runner", answers ? "PokiCore asked for a restart; the runner answers, so it was kept" : "PokiCore asked for a restart; the runner does not answer: restarting it") }
                if !answers { launcher.restart() }
            }
        }
        host.onWake { [weak self] in Task { @MainActor in self?.wakeRunner() } }
        host.onWarmUp { [weak self] in Task { @MainActor in self?.warmInProcess("an agent connected") } }
        if automationPath == .inProcess {
            host.onRetry { [weak self] in Task { @MainActor in self?.requestAutomationForTask("an agent's call while the session was not open") } }
        }
        // Allow and Deny on the Live Activity run in this process and come straight here.
        ApprovalIntentBridge.install { [weak self] decision in
            guard let self else { return false }
            self.decide(decision)
            return true
        }
        // The same answers from the approval notification's own buttons.
        ApprovalNotice.registerActions()
        listenForApprovals()
        // One pump for the app's whole life. Cancelling a task that reads an AsyncStream ends the
        // stream for good, so a pump per session would go silent after the first Turn off (no steps,
        // no approvals, no relay state in the log, which is what happened on the phone).
        eventsTask = Task { [weak self, core] in
            for await event in core.events { self?.handle(event) }
        }
        loopback.onChange = { [weak self] old, new in self?.loopbackChanged(from: old, to: new) }
        // A built-in tunnel that fails or drops while Poki is on dials again by itself; the loopback
        // check that follows lets `loopbackChanged` start the runner, as for any other recovery.
        tunnel.wanted = { [weak self] in self?.sessionOn == true && self?.setup.loopback == .builtIn }
        tunnel.onReconnected = { [weak self] in self?.loopback.check() }
        // When Poki detects the owner's own VPN it stops: the tunnel says so here, and the problem clears when it is back.
        tunnel.onAttention = { [weak self] text in
            guard let self else { return }
            if let text { problem = text; tunnelAttention = text }
            else if problem == tunnelAttention { problem = nil; tunnelAttention = nil }
        }
        if !diskImage.isReady { Task { await diskImage.download() } }
        // Just installed by Poki Setup on a computer (its signing key still waits in the container, and
        // the owner never turned Poki on or off): Poki turns on by itself, so it does not stand at Off.
        if UserDefaults.standard.object(forKey: "wantsOn") == nil, FileManager.default.fileExists(atPath: SelfSigner.handedIdentity.path) {
            wantsOn = true
            log.add("session", "installed by Poki Setup: Poki turns on by itself")
        }
        // The installer on the Mac reads the hello and may leave a sealed model key while Poki is in front.
        handoffTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.inFront == true { self?.handoffTick() } }
        }
        // An agent whose session began before this launch is named from its connector.
        SessionStore.shared.connectorAgent = { [identity] hash in
            identity.secrets.first { $0.hash == hash }.map { $0.named ? $0.name : ($0.agent ?? $0.name) }
        }
        if UserDefaults.standard.string(forKey: "pokiSample") != nil { loadSample() }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
        // Installed over the local-VPN build (both use one bundle ID): this build has only external
        // connections, so a saved built-in choice becomes the external one. Otherwise Setup showed the
        // step done while Turn on said this build has no local VPN.
        if setup.loopback == .builtIn, !tunnel.available {
            setup.loopback = .proxy
            setup.save()
            log.add("loopback", "this build has no built-in connection: the saved choice is now an external one")
        }
    }

    /// The in-process session as prepare last answered it in this process (ESP-152).
    private var inProcessSession = InProcessSession.opening
    /// Poki's own automation session (ESP-152); a fake in tests.
    private let automation: InProcessAutomation
    private var inProcessWarming = false
    /// iOS is asking the owner for the passcode to allow automation (in-process): an open has not
    /// answered in 5 s. The Live Activity and Poki's home ask the owner, and the agent reads that the
    /// owner has to enter it.
    private var inProcessPasscode = false
    /// When the open under way began: one that has not answered in `staleOpen` seconds no longer
    /// holds the next one back (seen on the phone: the banner up, the session open, and every look
    /// answered "still starting" because an open that never answered blocked all the others).
    private var inProcessWarmStarted = Date.distantPast
    private static let staleOpen: TimeInterval = 15
    /// Counts closes, so an open that began before one is not taken as the state after it.
    private var inProcessEpoch = 0
    private var inProcessWarmToken = 0
    /// A session of this launch was closed. One reopened in the same launch answers no reads (the
    /// phone, builds 144-149: every look timed out after a stand-by, a restart, or Off then On), so
    /// Poki starts again as a new process for the next one instead.
    private var inProcessUsedUp = false

    /// Ends the in-process session (Automation Mode and the banner go with it) off the main thread.
    /// PokiCore's next request finds its session gone and opens a new one through prepare.
    func closeInProcess(_ why: String, then: (@MainActor () -> Void)? = nil) {
        guard automationPath == .inProcess else { return }
        inProcessSession = .opening
        // An open that was still under way when this close came answers for a session that is gone:
        // its answer is not taken (it would show .open, or keep .opening for good).
        inProcessEpoch += 1
        inProcessWarming = false
        endPasscodeWait(opened: false)
        DispatchQueue.global(qos: .userInitiated).async { [automation] in
            let result = automation.close()
            Task { @MainActor [weak self] in
                let closed = (result["closed"] as? Bool) == true
                if closed { self?.inProcessUsedUp = true }
                self?.log.add("runner", closed ? "in-process session closed for \(why) (generation \(result["generation"] ?? 0)); the banner goes with it" : "in-process session was not open (\(why))")
                then?()
            }
        }
    }

    /// Automation Mode off with the session kept (its banner goes; the session's reads stay), off the
    /// main thread. The log says how, or what the session offers when it found no way.
    private func pauseAutomationMode() {
        guard automationPath == .inProcess, !Self.onSimulator else { return }
        DispatchQueue.global(qos: .userInitiated).async { [automation] in
            let result = automation.pauseAutomation()
            Task { @MainActor [weak self] in
                let paused = (result["paused"] as? Bool) == true
                self?.log.add("runner", paused ? "Automation Mode turned off while standing by (\(result["how"] ?? "?")): the banner goes until an agent asks"
                                               : "Automation Mode could not be turned off alone (\(result["how"] ?? "?"); the session offers: \(result["selectors"] ?? "nothing")): the banner stays while Poki is on")
            }
        }
    }

    /// Opens (or checks) the in-process session off the main thread before an agent needs it: when
    /// the launcher has mounted the disk image, when Poki comes to the front, when an agent
    /// connects, and when an agent's call finds the last try failed. prepare is idempotent: a session
    /// already open answers "reused" in milliseconds.
    func warmInProcess(_ why: String) {
        guard automationPath == .inProcess, sessionOn, runner.isRunning, automationRequested || probeDriven else { return }
        if InProcessWDA.automationDeclined { return }
        if inProcessWarming {
            guard Date().timeIntervalSince(inProcessWarmStarted) > Self.staleOpen else { return }
            log.add("runner", "the in-process open under way has not answered in \(Int(Self.staleOpen)) s: asking again for \(why)")
        }
        inProcessWarming = true
        inProcessWarmStarted = Date()
        inProcessWarmToken += 1
        let epoch = inProcessEpoch, token = inProcessWarmToken
        if inProcessSession != .open, inProcessSession != .opening, inProcessSession != .waitingForPasscode {
            inProcessSession = .opening
            host.update(runner: coreState(of: runner))
        }
        DispatchQueue.global(qos: .userInitiated).async { [automation] in
            let result = InProcessWDA.openThroughGate { automation.prepare() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard epoch == self.inProcessEpoch else {
                    self.log.add("runner", "an in-process open for \(why) answered after the session was closed: not taken")
                    return
                }
                // Only the latest open's answer clears the flag (a stale one was asked again meanwhile).
                let ok = (result["ok"] as? Bool) == true
                // A stale open's failure does not undo what a newer one is doing.
                guard token == self.inProcessWarmToken || ok else { return }
                if token == self.inProcessWarmToken { self.inProcessWarming = false }
                let waitedForPasscode = self.inProcessPasscode
                self.endPasscodeWait(opened: ok)
                let seconds = String(format: "%.2f", result["seconds"] as? Double ?? 0)
                let warm = (result["warm_seconds"] as? Double).map { $0 > 0 ? String(format: ", first snapshot and screenshot %.2f s", $0) : "" } ?? ""
                self.log.add("runner", ok ? "in-process session ready for \(why) (generation \(result["generation"] ?? 0), \((result["reused"] as? Bool) == true ? "already open" : "opened"), \(seconds) s\(warm))"
                                          : "in-process session not ready for \(why): \(result["code"] ?? "unknown") after \(seconds) s")
                if ok { self.automationStarted() }
                let detail = result["detail"] as? String ?? ""
                // iOS gives up on the passcode after a minute and says only that enabling timed out.
                let passcodeMissed = waitedForPasscode || detail.localizedCaseInsensitiveContains("enabling automation mode")
                // Cancelled (or left) iOS's passcode screen: Poki does not open it again by itself.
                if !ok, passcodeMissed {
                    InProcessWDA.gate.withLock { $0.declined = true }
                    self.log.add("runner", "the passcode for automation was not entered: Poki will not ask again until it is turned on again")
                }
                self.inProcessSession = ok ? .open : passcodeMissed ? .passcodeMissed : .failed(code: "\(result["code"] ?? "unknown")", detail: detail)
                if self.sessionOn { self.host.update(runner: self.coreState(of: self.runner)) }
            }
        }
    }

    /// An open has taken over 5 s: iOS is asking for the passcode before it allows automation (after
    /// Poki restarts, and 8 hours after the last time). Asked as the runner path's launcher asks.
    private func beginPasscodeWait() {
        inProcessPasscode = true
        passcodeHint = true
        log.add("runner", "the in-process session has not opened for 5 s: asking the owner for the passcode on the Live Activity")
        inProcessSession = .waitingForPasscode
        host.update(runner: coreState(of: runner))
        activity.update { $0.phase = .handoff; $0.handoff = .init(id: Self.runnerPasscodeHandoff, kind: .automationPasscode, text: nil, app: nil, since: Date()) }
    }

    private func endPasscodeWait(opened: Bool) {
        guard inProcessPasscode else { return }
        inProcessPasscode = false
        passcodeHint = false
        log.add("runner", opened ? "the passcode was entered: the in-process session is open" : "the in-process session did not open while iOS asked for the passcode")
        if activity.state.handoff?.id == Self.runnerPasscodeHandoff {
            activity.update { $0.handoff = nil; $0.phase = .idle; if opened { $0.headline = "Ready for the agent" } }
        }
    }

    /// Poki came to the front: turn on again if it was on, check the loopback live, and finish a
    /// setup step the person just did in Settings.
    func becameActive() {
        inFront = true
        InProcessWDA.gate.withLock { $0.inFront = true }
        cameToFront = Date()
        // A pairing file and disk image Poki Setup put in the container while Poki was running (or
        // since it last came to the front) count at once: mirrored to the Keychain, the disk image
        // checked again, and the pairing checked as soon as the loopback answers.
        SetupVault.mirrorPairingFromContainer()
        lookForHandedPairing()
        handoffTick()
        diskImage.notice()
        warmInProcess("Poki came to the front")
        loopback.resume()
        // Swiped away, ended by iOS, or Poki turned on from the background (where iOS starts none):
        // the Live Activity comes back while Poki is on, so the next thing that needs the owner pops up.
        if sessionOn, !activity.isRunning {
            activity.start(deviceName: deviceName)
            if activity.isRunning { log.add("activity", "Live Activity started again (Poki came to the front)") }
        }
        // Poki in front while an agent's step is under way: nobody opened it on purpose. A tap near the
        // top of the screen hit the expanded Dynamic Island (iOS opens the activity's app), or the agent
        // tapped the activity's own label in the tree. Logged so the phone log shows it; PokiCore sends
        // the agent back to the app it was in.
        if sessionOn, let step = stepUnderWay, Date().timeIntervalSince(step.started) < 20 {
            log.add("app", "Poki came to the front during a step (\(step.summary)): a tap hit the Live Activity")
        }
        turnOnIfWanted()
        if let step = guiding, isDone(step) { stopGuide() }
    }

    /// Turns on when Poki was on (or Poki Setup just installed it) and the pairing and disk image are there.
    private func turnOnIfWanted() {
        Task {
            await tunnel.refresh()
            if wantsOn, !sessionOn, pairingPath != nil, diskImage.isReady { startSession(reconnectLocal: false) }
        }
    }

    // MARK: Hand-off with the installer on the Mac (PokiHandoff)

    /// Takes a model key the installer sealed to this phone, then tells the installer how Poki is.
    /// A key that just came may be what Poki needed to turn on.
    func handoffTick() {
        if let what = PokiHandoff.takeSealedKey() {
            log.add("setup", what)
            turnOnIfWanted()
        }
        PokiHandoff.writeHello(loopbackWorking: loopback.isWorking, loopbackSay: loopback.isWorking ? nil : loopbackSentence)
    }

    /// The one thing to do for the local connection, for the person, as the installer says it.
    var loopbackSentence: String {
        if tunnel.available { return "In Poki, open Setup > Connect to this iPhone and turn on Poki's own connection." }
        guard let app = ProxyApps.all.first(where: \.isInstalled) else {
            return "Install a VPN app that can reach 10.7.0.1 (Karing, Surge, Loon or Shadowrocket), then in Poki open Setup > Connect to this iPhone."
        }
        switch app.install {
        case .url: return "In Poki, open Setup > Connect to this iPhone > \(app.name), tap Install, then confirm in \(app.name)."
        case .toggle(let setting): return "In \(app.name), set \(setting), and keep \(app.name) connected."
        case .snippet: return "In Poki, open Setup > Connect to this iPhone > \(app.name) and add the lines it shows to \(app.name)."
        }
    }

    /// In the background the loopback is still watched while Poki is on (the agent's runner depends on
    /// it): every 6 s, light enough for the location-kept background time.
    func wentToBackground() {
        inFront = false
        InProcessWDA.gate.withLock { $0.inFront = false }
        sessionOn ? loopback.resume(every: 6) : loopback.pause()
        if pairingUnderWay { log.add("pairing", "Poki in the background while pairing; keep-alive \(pairingKeepAlive.isOn ? "playing" : "off")") }
    }
    private var inFront = true
    private var cameToFront = Date()

    /// Poki is being closed: end the runner now (the launcher kills its process) instead of leaving
    /// iOS's automation banner up for half a minute. iOS gives a few seconds for this.
    private func appWillTerminate() {
        // The Live Activity goes with the app; the pause below gives its end time to reach iOS.
        ActivityController.endAll()
        guard sessionOn else { Thread.sleep(forTimeInterval: 0.5); return }
        log.add("app", "Poki is closing: ending the runner")
        if automationPath == .inProcess { _ = automation.close() }
        launcher.stop()
        Thread.sleep(forTimeInterval: 2.5)
    }

    var deviceName: String { UIDevice.current.name }

    /// `-pokiSample B` (YES is B), `C` or `PIN`: the home screen states of ESP-139 board 01 with sample
    /// steps and an approval, only for the build's screenshots. Nothing is started: B and D look like a
    /// session at work, C like one standing by (the loopback check stays live, so a simulator shows it
    /// off). A sample relay address (not saved) and, on a simulator, two agents are added when there are none.
    private func loadSample() {
        let scene = UserDefaults.standard.string(forKey: "pokiSample")?.uppercased() ?? "B"
        // PIN: setup's pairing page with a sample code, as if Settings had asked for one.
        if scene == "PIN" { pairing = .pin("482913"); return }
        let now = Date()
        let messages = String(localized: "Messages")
        // The sample relay is not saved. Sample agents go into the keychain, so only a simulator gets them.
        if relayAddress == nil { relayAddress = RelayAddress("https://your-relay.example") }
        #if targetEnvironment(simulator)
        if identity.secrets.isEmpty {
            _ = addConnector(name: "")
            _ = addConnector(name: "")
        }
        #endif
        Thumbnail.previewImage = ActivityPreview.sampleScreen()
        sessionOn = true
        relayStatus = .ready
        currentApp = messages
        if scene == "C" {
            runnerPaused = true
            runner = RunnerStatus(state: "standby", detail: "It starts when an agent asks.")
            recentSteps = (0..<12).map { i in
                RecentStep(text: String(localized: "Tap “Send”"), app: messages, at: now.addingTimeInterval(Double(i - 11) * 84 / 11 - 300))
            }
            return
        }
        runner = RunnerStatus(state: "running")
        recentSteps = [
            RecentStep(text: String(localized: "Open Messages"), app: String(localized: "Home Screen"), at: now.addingTimeInterval(-70)),
            RecentStep(text: String(localized: "Tap the chat with Mom"), app: messages, at: now.addingTimeInterval(-52)),
            RecentStep(text: String(localized: "Type “On my way”"), app: messages, at: now.addingTimeInterval(-41)),
            RecentStep(text: "Tap at 212, 640", app: messages, failure: "failed: nothing changed", at: now.addingTimeInterval(-30)),
        ]
        activityText = String(localized: "Tap “Send”")
        approvals = [PendingApproval(id: "sample", app: messages, summary: String(localized: "Send “On my way” to Mom"),
                                     reason: "sending a message (\"send\")", expires: now.addingTimeInterval(25))]
    }

    // MARK: Session

    func chooseConnection(_ method: SetupState.Loopback) {
        guard !connectionInUse, !tunnel.busy else { return }
        if method == .proxy { tunnel.disconnect() }
        setup.loopback = method
        setup.proxyApp = nil
        loopback.check()
    }

    /// A sign-in from a client outside the relay's known list, waiting for the owner (an alert in the
    /// app and a notification). The relay gives up after 90 s, and so does this.
    struct ConnectionAsk: Identifiable {
        let id = UUID()
        let client: String
        let callback: String
        let connector: String
    }
    private(set) var connectionAsk: ConnectionAsk?
    private var connectionAnswer: CheckedContinuation<Bool, Never>?

    func askToConnect(client: String, callback: String, connector: String) async -> Bool {
        answerConnection(false) // one at a time: an older ask is declined
        let name = identity.secrets.first { $0.hash == connector }?.name ?? String(localized: "a connector")
        let ask = ConnectionAsk(client: client, callback: callback, connector: name)
        log.add("relay", "\(client) at \(callback) asks to sign in through \(name): waiting for the owner")
        ConnectionNotice.post(ask)
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            connectionAsk = ask
            connectionAnswer = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(88))
                if self?.connectionAsk?.id == ask.id { self?.answerConnection(false) }
            }
        }
        log.add("relay", ok ? "the owner allowed \(client) at \(callback)" : "\(client) at \(callback) was not allowed")
        return ok
    }

    func answerConnection(_ ok: Bool) {
        guard let answer = connectionAnswer else { return }
        connectionAnswer = nil
        if let ask = connectionAsk { ConnectionNotice.clear(ask) }
        connectionAsk = nil
        answer.resume(returning: ok)
    }

    private var pairingCheck: Task<Bool, Never>?

    /// Asks the phone's own services, over the loopback, whether they still take this pairing file:
    /// the same handshake the runner makes, a second or two, so a refused pairing shows on Setup and
    /// the home page before an agent or a chat needs the phone. true when it was accepted (or could
    /// not be checked now: the loopback is down, or the simulator).
    /// A lockdown pairing record (from a computer: HostID, certificates), not an RPPairing file.
    static func isLockdownRecord(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        return dict["HostID"] != nil
    }

    /// The way to the phone's developer services when a check or the runner fails, for the log:
    /// whether Wi-Fi is up (iOS refuses the loopback on cellular) and which loopback carries it.
    private var networkNote: String {
        "loopback \(setup.loopback.rawValue), local VPN \(tunnel.state), Wi-Fi \(loopback.onWiFi ? "on" : "off")\(loopback.cellularOnly ? ", cellular only" : ""), path \(loopback.pathSummary)"
    }

    @discardableResult
    func verifyPairing(force: Bool = false) async -> Bool {
        if Self.onSimulator { return true }
        guard let path = pairingPath, loopback.isWorking else { return true }
        if !force, pairingTrouble == nil, let at = pairingVerifiedAt, Date().timeIntervalSince(at) < 600 { return true }
        if let pairingCheck { return await pairingCheck.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return true }
            defer { self.pairingCheck = nil }
            do {
                _ = try await SignerBridge.call(["op": "udid", "device_address": "10.7.0.1", "pairing_file": path, "host_name": "Poki"])
                if self.pairingTrouble != nil { self.log.add("pairing", "check: accepted again") }
                self.pairingTrouble = nil
                self.servicesSilent = false
                self.pairingVerifiedAt = Date()
                return true
            } catch {
                let text = error.localizedDescription
                let code = (error as? SignerError)?.code
                if code == "pairing" {
                    if self.pairingTrouble == nil { self.log.add("pairing", "check: refused: \(text)") }
                    self.pairingTrouble = text.replacingOccurrences(of: " Pair again in Poki's setup.", with: "")
                    return false
                }
                // iOS 27 and later take only a pairing made on the phone over the loopback: a lockdown
                // record from a computer (Poki Setup) fails its TLS session here every time.
                if SetupStep.onDevicePairing, text.contains("device socket io failed"), Self.isLockdownRecord(path) {
                    if self.pairingTrouble == nil { self.log.add("pairing", "check: the computer's pairing file does not open the loopback on this iOS; pair on this iPhone") }
                    self.pairingTrouble = String(localized: "the pairing file from a computer does not work over the loopback on this iOS version. Pair this iPhone here once; the pairing stays.")
                    return false
                }
                self.log.add("pairing", "check could not finish: \(text) [\(self.networkNote)]")
                if code == "handshake" { self.servicesSilent = true }
                return true
            }
        }
        pairingCheck = task
        return await task.value
    }

    func startSession(reconnectLocal: Bool = true) {
        guard !sessionOn, !sessionStarting else { return }
        // Turning on is the owner asking for automation again, after a cancelled passcode screen too.
        InProcessWDA.gate.withLock { $0.declined = false }
        if automationPath == .inProcess, inProcessUsedUp, !Self.onSimulator {
            // With Poki in front the owner is told first that it exits and must be opened again.
            if inFront { relaunchNotice = true } else { relaunchForFreshSession() }
            return
        }
        if setup.loopback == .none {
            problem = "Choose and enable a local connection first (Setup)."
            return
        }
        if setup.loopback == .builtIn, !tunnel.connected {
            guard reconnectLocal else {
                problem = "The local connection is off. Turn Poki on to reconnect, or choose an external connection in Setup."
                return
            }
            sessionStarting = true
            sessionStartTask = Task {
                defer { sessionStarting = false; sessionStartTask = nil }
                do {
                    try await tunnel.connect()
                    try Task.checkCancellation()
                    loopback.check()
                    if !(await verifyPairing()) {
                        problem = "The phone refused the pairing (\(pairingTrouble ?? "")). Pair again in Setup."
                        return
                    }
                    beginSession()
                } catch is CancellationError { }
                catch { problem = error.localizedDescription }
            }
        } else if loopback.isWorking, !Self.onSimulator, pairingPath != nil {
            // Check the pairing first, so a refused one stops here with its fix instead of failing
            // under the first agent's call.
            sessionStarting = true
            sessionStartTask = Task {
                defer { sessionStarting = false; sessionStartTask = nil }
                guard await verifyPairing(), !Task.isCancelled else {
                    if let pairingTrouble { problem = "The phone refused the pairing (\(pairingTrouble)). Pair again in Setup." }
                    return
                }
                beginSession()
            }
        } else { beginSession() }
    }

    private func beginSession() {
        guard !sessionOn else { return }
        problem = nil
        #if targetEnvironment(simulator)
        // A simulator has no pairing, disk image or launcher: the runner is WebDriverAgent started on
        // the Mac (see `launchRunner`).
        let pairing = pairingPath ?? ""
        #else
        guard let pairing = pairingPath else { problem = "Pair this iPhone first (Setup)."; return }
        #endif
        // The chat's own model loop needs no relay; agents on a computer do.
        let relay = activeRelay
        guard relay != nil || ModelKeys.hasUsableKey else { problem = Self.noRelay; return }
        if !inFront { loopback.resume(every: 6) }
        guard Self.onSimulator || diskImage.isReady && diskImage.recheck() else {
            problem = "The developer disk image is not downloaded yet (Setup > Pair). It is needed once."
            Task { await diskImage.download() }
            return
        }
        log.add("session", "turned on")
        background.start()
        ApprovalNotice.requestPermission()
        stopGuide()
        activity.start(deviceName: deviceName)
        log.add("activity", activity.isRunning ? "Live Activity started" : "Live Activity not running: \(activity.lastError ?? "unknown reason")")
        sessionOn = true
        wantsOn = true
        launcherConfig = LauncherConfig(pairing_file: pairing, ddi_dir: AppFiles.ddiDirectory.path, in_process: automationPath.mountsOnly)
        lastAgentActivity = Date()
        // The runner (and with it iOS's automation banner) starts only when an agent asks.
        standBy(reason: nil)
        if let relay { core.start(relay: relay) }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkIdle() } }
    }

    /// Turned on again after a session of this launch was closed: Poki starts over as a new process
    /// (the only way to a session that reads the screen) and comes back on by itself. A notice reopens
    /// it; `wantsOn` turns it on when it does.
    /// Off by hand, in-process: Poki leaves for the Home Screen and exits, so the next turn-on is a
    /// fresh launch whose session can read the screen; the notice brings the owner back.
    private func exitAfterStop() {
        guard !Self.onSimulator, !sessionOn, !exitingAfterStop else { return }
        exitingAfterStop = true
        log.add("session", "turned off: Poki exits, and opening it again starts the next task")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Open Poki Again to Start Another Task")
        content.body = String(localized: "Poki closed after you stopped it. Open it to turn it on again.")
        content.userInfo = ["poki_link": "poki://chat"]
        content.sound = .default
        // Shown at once (the delegate shows banners while Poki is open too); Poki leaves only after
        // iOS has taken the notification, so an exit cannot drop it.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nz.zheha.poki.stopped", content: content, trigger: nil)) { error in
            Task { @MainActor [weak self] in
                self?.log.add("session", error.map { "the reopen notice was not posted: \($0.localizedDescription)" } ?? "reopen notice posted")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    UIApplication.shared.perform(NSSelectorFromString("suspend"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
                }
            }
        }
    }
    private var exitingAfterStop = false

    /// The note before Poki exits to turn on again (Continue exits).
    var relaunchNotice = false
    func continueRelaunch() {
        relaunchNotice = false
        relaunchForFreshSession()
    }

    private func relaunchForFreshSession() {
        log.add("session", "turning on after the automation session was closed: Poki restarts so agents can see the screen")
        wantsOn = true
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Tap to Open Poki")
        content.body = String(localized: "Poki restarted so agents can see the screen again. It turns on when it opens.")
        content.userInfo = ["poki_link": "poki://chat"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nz.zheha.poki.relaunch", content: content,
                                                                      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
        }
    }

    /// The owner tapped Install: Poki winds down for iOS to replace it. The automation session (and
    /// its banner) closes, the Live Activity ends, the log is written; the loopback stays, since the
    /// install runs over it. `wantsOn` is kept, so Poki turns on again when it reopens.
    func windDownForUpdate() {
        log.add("signing", "installing the update: winding down (Poki closes, then reopens from the notice)")
        if automationPath == .inProcess { closeInProcess("the update") }
        if automationPath == .nativeServices { Task { [nativeServicesWDA] in await nativeServicesWDA?.reset() } }
        activity.end()
        AttentionNotice.clear()
    }

    func stopSession() {
        automationRequested = false
        sessionStartTask?.cancel()
        wantsOn = false
        guard sessionOn else {
            if setup.loopback == .builtIn { tunnel.disconnect() }
            return
        }
        if !inFront { loopback.pause() }
        log.add("session", automationPath == .inProcess ? "turned off: closing the in-process session" : automationPath == .nativeServices ? "turned off: ending native services" : "turned off: ending the runner")
        // In-process, a session closed in this launch cannot be opened again in it: Poki exits once
        // the session has closed, and a notice says to open it again for the next task.
        if automationPath == .inProcess {
            closeInProcess("turned off") { [weak self] in self?.exitAfterStop() }
            // A close that hangs does not keep Poki from exiting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.exitAfterStop() }
        }
        core.stop()
        if automationPath == .nativeServices { Task { [nativeServicesWDA] in await nativeServicesWDA?.reset() } }
        launcher.stop()
        if setup.loopback == .builtIn { tunnel.disconnect() }
        if automationPath == .runner {
            if !Self.onSimulator { Task { await RunnerProbe.shutdown() } }
            confirmRunnerEnded()
        }
        idleTimer?.invalidate(); idleTimer = nil
        runnerPaused = false; host.setPaused(false)
        background.stop()
        activity.end()
        sessionOn = false
        stepUnderWay = nil
        runner = .idle
        relayStatus = .off
        activityText = "Idle"
    }

    func restartRunner() {
        if automationPath == .nativeServices {
            Task { [nativeServicesWDA] in await nativeServicesWDA?.reset() }
        } else {
            launcher.restart()
        }
    }

    #if targetEnvironment(simulator)
    static let onSimulator = true
    #else
    static let onSimulator = false
    #endif

    private func launchRunner() {
        #if targetEnvironment(simulator)
        // On a simulator, WebDriverAgent runs from Xcode on the Mac (`xcodebuild test` of
        // WebDriverAgentRunner, as in .github/workflows/ios-core.yml) and answers on 127.0.0.1:8100.
        Task { [weak self] in
            let up = await RunnerProbe.answers()
            self?.runnerChanged(up ? RunnerStatus(state: "running") :
                RunnerStatus(state: "failed", detail: "WebDriverAgent is not answering on 127.0.0.1:8100", fix: "Start WebDriverAgentRunner on this simulator from Xcode"))
        }
        return
        #else
        guard let launcherConfig else { return }
        do {
            try launcher.start(config: launcherConfig) { [weak self] status in Task { @MainActor in self?.runnerChanged(status) } }
        } catch { runnerChanged(RunnerStatus(state: "failed", detail: "\(error)")) }
        #endif
    }

    /// Stops the runner, and with it iOS's automation banner, while the relay stays connected; the
    /// next agent request starts it again. From the Stop runner button, the Live Activity, or idle.
    func pauseRunner(reason: String = "Stopped") {
        guard sessionOn, !runnerPaused, approvals.isEmpty else { return }
        // Allow on the Live Activity is followed by its layout changing under the finger: a Stop
        // that lands within a few seconds of an answered approval is that same tap (build 144: an
        // Allow, then "Stopped from the Live Activity" 0.7 s after the approval ended).
        if reason == "Stopped from the Live Activity", let answered = lastApprovalAnswered, Date().timeIntervalSince(answered) < 4 {
            log.add("runner", "a Stop from the Live Activity right after an approval was ignored")
            return
        }
        if automationPath == .inProcess {
            // The in-process session is closed, and with it Automation Mode and iOS's banner; the
            // next agent request opens a new one (a few seconds, no passcode within the same boot).
            // The session stays open while Poki is on: a session reopened in the same launch answered
            // no tree reads on the phone (0.2.8 build 144, after a stand-by every look timed out until
            // Poki was relaunched), so standing by ends the task and leaves the session (and iOS's
            // banner) as they are. Turning Poki off still closes it.
            // Without closing it, Automation Mode alone is turned off where iOS offers a way, so the
            // banner shows only while an agent works; the next request's prepare turns it on again.
            log.add("runner", closeSessionWhenIdle ? "standing by: \(reason); closing the in-process session, and the banner with it"
                                                   : "standing by: \(reason); the in-process session stays open, Automation Mode (the banner) is turned off")
            // The task ends here too, as with the runner (ESP-176): nothing is switched.
            Task { [core] in _ = await core.finishTask(switching: false) }
            if closeSessionWhenIdle { closeInProcess("standing by") } else { pauseAutomationMode() }
            // The launcher stays: the disk image is mounted and the next session opens through
            // testmanagerd on the phone itself, so no loopback (and no Wi-Fi) is needed to wake.
            standBy(reason: reason)
            return
        }
        if automationPath == .nativeServices {
            log.add("runner", "standing by: \(reason); closing the experimental native-services tunnel")
            Task { [core, nativeServicesWDA] in
                _ = await core.finishTask(switching: false)
                await nativeServicesWDA?.reset()
            }
            launcher.stop()
            standBy(reason: reason)
            return
        }
        log.add("runner", "stopping: \(reason)")
        // The task ends with the runner; a client ending its session later sends nothing to it.
        Task { [core] in _ = await core.finishTask(switching: false) }
        // The runner is asked to shut itself down (it ends its test and exits) and the launcher's
        // session is closed; the launcher also ends the process through the developer services.
        if !Self.onSimulator { Task { await RunnerProbe.shutdown() } }
        launcher.stop()
        standBy(reason: reason)
        confirmRunnerEnded()
    }

    /// After a stop, watches the runner until it really ends (and with it the automation banner):
    /// once a second for 30 s. The log says how long it took. If it is still there after 10 s, the
    /// home screen says so, and the notice goes away by itself the moment the runner is gone.
    func confirmRunnerEnded() {
        // A simulator's runner belongs to Xcode on the Mac and stays up.
        guard !Self.onSimulator else { return }
        endCheck += 1
        let check = endCheck
        Task { [weak self] in
            for second in 1...30 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.endCheck == check else { return }
                // An agent asked for the runner again in the meantime: nothing to watch.
                if self.sessionOn, !self.runnerPaused { self.clearStuckNotice(); return }
                if !(await RunnerProbe.answers()) {
                    self.log.add("runner", "ended \(second) s after Stop")
                    self.clearStuckNotice()
                    return
                }
                // Still up: the shutdown may have queued behind a long read in the runner, or the
                // developer connection the launcher kills through was gone. Ask again.
                if second == 4 || second == 12 || second == 20 {
                    self.log.add("runner", "still answering \(second) s after Stop: asking again")
                    await RunnerProbe.shutdown()
                    self.launcher.stop()
                }
                if second == 10 {
                    self.log.add("runner", "still answering 10 s after Stop")
                    self.problem = Self.stuckNotice
                }
            }
            guard let self, self.endCheck == check else { return }
            self.log.add("runner", "still answering 30 s after Stop")
        }
    }

    private static let stuckNotice = "Poki Runner is still running after Stop. Swipe it away in the app switcher; the banner goes with it."
    private func clearStuckNotice() { if problem == Self.stuckNotice { problem = nil } }

    /// The runner is off and starts on the next agent request.
    private func standBy(reason: String?) {
        runnerPaused = true
        runner = RunnerStatus(state: "standby", detail: reason.map { "\($0). It starts again when an agent asks." } ?? "It starts when an agent asks.")
        host.update(runner: .starting(automationPath == .inProcess ? "opening the automation session" : automationPath == .nativeServices ? "opening native services" : "starting the runner"))
        host.setPaused(true)
        activityText = "Idle"
        activity.update { $0.runnerPaused = true; $0.phase = .idle; $0.headline = "Runner asleep"; $0.since = nil }
    }

    /// Starts a paused runner again (the next agent request, or the owner).
    func wakeRunner() {
        guard sessionOn, runnerPaused else { return }
        runnerPaused = false
        host.setPaused(false)
        lastAgentActivity = Date()
        log.add("runner", automationPath == .inProcess ? "an agent asked: opening the automation session again" : automationPath == .nativeServices ? "an agent asked: opening native services again" : "an agent asked: starting the runner")
        activity.update {
            $0.runnerPaused = false
            guard $0.approval == nil, $0.handoff == nil else { return }
            $0.phase = .working
            $0.headline = stepUnderWay?.summary ?? (automationPath == .nativeServices ? "Starting native services" : "Starting the runner")
            $0.since = stepUnderWay?.started ?? Date()
        }
        if automationPath == .inProcess, inProcessUsedUp {
            log.add("runner", "an agent asked, but the session of this launch was closed: open Poki to start it again")
            problem = String(localized: "Open Poki so agents can see the screen again: it restarts once.")
            AttentionNotice.post(title: String(localized: "Open Poki"), body: String(localized: "An agent is waiting. Open Poki so it can see the screen again."))
        }
        if automationPath == .inProcess, runner.isRunning { warmInProcess("an agent asked"); return }
        launchRunner()
    }

    func checkIdle(now: Date = Date()) {
        if automationPath == .inProcess, inProcessWarming, !inProcessPasscode, now.timeIntervalSince(inProcessWarmStarted) > 5 {
            beginPasscodeWait()
        }
        passcodeHint = inProcessPasscode || runner.state == "launching" && launchingSince.map { now.timeIntervalSince($0) > 10 } == true
        // On both paths the automation (the runner, or the in-process session) ends after the idle
        // time, so iOS's banner shows only while an agent works; the next request starts it again.
        guard sessionOn, activity.state.agentTask?.active != true, !runnerPaused, idleStopSeconds > 0, approvals.isEmpty, activityText == "Idle" else { return }
        if now.timeIntervalSince(lastAgentActivity) >= Double(idleStopSeconds) {
            let reason = "Stopped after \(idleStopSeconds / 60 > 0 ? "\(idleStopSeconds / 60) min" : "\(idleStopSeconds) s") without agent activity"
            // The task is over: the phone goes back to the app it began in while the runner can still
            // switch apps, then the runner stops unless an agent came back meanwhile.
            Task { [weak self, core] in
                let line = await core.finishTask()
                guard let self else { return }
                if let line { self.log.add("runner", line) }
                guard self.activityText == "Idle", Date().timeIntervalSince(self.lastAgentActivity) >= Double(self.idleStopSeconds) else { return }
                self.pauseRunner(reason: reason)
            }
        }
    }

    /// The loopback came or went. Going: logged with the time, and the agent's status says so instead
    /// of "Checking pairing". Back: the launcher tries at once instead of waiting out its backoff
    /// (the runner dies with the tunnel, so every drop costs a restart).
    func loopbackChanged(from old: LoopbackMonitor.State, to new: LoopbackMonitor.State) {
        let wasWorking = { if case .working = old { true } else { false } }()
        // 10.7.0.1 answers with no connection chosen in Setup: something outside Poki (a proxy app set
        // up before, or by Poki Setup) provides it. The external connection is the recorded choice, so
        // Setup's loopback step is done and Turn on does not ask to choose one (0.2.8 build 91: the step
        // never let the owner continue although the loopback was on).
        if loopback.isWorking, setup.loopback == .none {
            setup.loopback = .proxy
            log.add("loopback", "10.7.0.1 answers already: the external connection is the recorded choice")
        }
        if wasWorking, !loopback.isWorking {
            log.add("loopback", "dropped: 10.7.0.1 stopped answering (\(loopback.state)); the runner cannot survive this")
        } else if !wasWorking, loopback.isWorking, old != .checking {
            log.add("loopback", "back: 10.7.0.1 answers again" + (sessionOn && !runner.isRunning && !runnerPaused ? "; starting the runner now" : ""))
            if sessionOn, !runner.isRunning, !runnerPaused { launcher.restart() }
        }
        // The loopback answers: check the pairing now, before anything needs it.
        if !wasWorking, loopback.isWorking { Task { await verifyPairing() } }
        // The signer's check at launch ran before the loopback was up and skipped the download: it
        // looks again now that it can reach the phone.
        if !wasWorking, loopback.isWorking { signer.maintain() }
        if sessionOn { host.update(runner: coreState(of: runner)) }
    }

    /// The runner's state as the agent reads it. While the loopback is down, every pre-launch state
    /// is the same thing: waiting for the tunnel, said with the time it went and what to do.
    func coreState(of status: RunnerStatus) -> RunnerState {
        // In-process, a running launcher only mounted the disk image; tools wait for the session.
        if automationPath == .inProcess, status.state == "running", inProcessSession != .open {
            return inProcessSession.agentState
        }
        if status.code == "passcode" {
            return .starting("the phone is asking the owner for the passcode (iOS does this once before the first automation after a restart or a force quit); the Live Activity tells the owner; the runner starts the moment it is entered. Call again in about 10 s; nothing is lost and no action is needed from you")
        }
        let preLaunch = ["connecting", "pairing", "tunnel", "waiting_network", "standby", "idle"].contains(status.state)
        if preLaunch, !loopback.isWorking, loopback.state != .checking || status.state == "waiting_network" {
            if loopback.cellularRefused {
                let since = loopback.droppedAt.map { " since \(Self.clock.string(from: $0))" } ?? ""
                return .starting("waiting for Wi-Fi\(since): the phone has only cellular, and iOS refuses the developer services' loopback there. The owner connects Wi-Fi and opens Poki; the runner starts by itself, and once it runs the phone can switch back to cellular. Nothing on the phone changes meanwhile")
            }
            return .waitingForLoopback(since: loopback.droppedAt.map(Self.clock.string(from:)),
                                       tunnelWithoutAnswer: loopback.state == .noAnswer,
                                       connection: setup.loopback == .builtIn ? .builtIn : .external)
        }
        return status.coreState
    }
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func runnerChanged(_ status: RunnerStatus) {
        if status != runner { log.add("runner", "\(status.state)\(status.detail.map { ": \($0)" } ?? "")\(status.state == "failed" && runner.state != "failed" ? " [\(networkNote)]" : "")") }
        // Events from a launcher that was stopped for idle are old news.
        guard !runnerPaused else { return }
        switch status.state {
        case "launching", "running":
            // The phone accepted the pairing.
            if pairingTrouble != nil { log.add("pairing", "accepted again") }
            pairingTrouble = nil
            servicesSilent = false
            pairingVerifiedAt = Date()
            // The disk image mounted and the runner is starting, so Developer Mode is on; a running
            // runner means UI Automation is on too. Setup's confirm steps tick themselves (a pairing
            // file from Poki Setup then needs nothing more on the phone).
            if !setup.developerMode { setup.developerMode = true; log.add("setup", "Developer Mode is on (the runner started)") }
            if status.state == "running", automationPath != .nativeServices, !setup.uiAutomation { setup.uiAutomation = true; log.add("setup", "UI Automation is on (the runner runs)") }
            if status.state == "running", automationPath == .runner { automationStarted() }
            if status.state == "launching", runner.state != "launching" { launchingSince = Date() }
        case "failed" where status.code == "handshake":
            servicesSilent = true
        case "failed" where status.code == "pairing":
            if pairingTrouble == nil { log.add("pairing", "refused: \(status.detail ?? "")") }
            pairingTrouble = status.detail ?? "The phone refused the pairing."
        default: break
        }
        if status.state != "launching" { launchingSince = nil; passcodeHint = inProcessPasscode }
        if status.code == "passcode", runner.code != "passcode" {
            // iOS is asking for the passcode before the first UI automation after a restart. The
            // launcher waits minutes for it; the person is asked on the Live Activity, and the agent
            // reads a plain "starting" meanwhile (coreState).
            passcodeHint = true
            log.add("runner", "the runner has not answered for 12 s: asking the owner for the passcode on the Live Activity")
            activity.update { $0.phase = .handoff; $0.handoff = .init(id: Self.runnerPasscodeHandoff, kind: .runnerPasscode, text: nil, app: nil, since: Date()) }
        }
        if status.isRunning, activity.state.handoff?.id == Self.runnerPasscodeHandoff {
            activity.update { $0.handoff = nil; $0.phase = .idle; $0.headline = "Ready for the agent" }
        }
        if status.code == "ddi_bad", runner.code != "ddi_bad" {
            log.add("ddi", "the phone would not install the disk image: downloading it again")
            diskImage.redownload()
        }
        runner = status
        host.update(runner: coreState(of: status))
        // Open an in-process session only after a real phone tool requests automation;
        // ordinary app visits stay quiet even when the launcher is ready.
        if status.state == "running" { warmInProcess("the launcher is ready") }
        // The external-display task has its own lifecycle. A separate primary-display transport
        // becoming idle or failing must not replace its progress or image.
        if activity.state.agentTask?.background == true, activity.state.agentTask?.active == true { return }
        if status.state == "failed" {
            let title = Self.problemText(code: status.code, fix: status.fix ?? status.detail ?? "The runner stopped")
            activity.update { $0.phase = .problem; $0.label = "Runner Stopped"; $0.headline = title }
        } else if activity.state.approval != nil || activity.state.handoff != nil {
            // Runner readiness must not replace a decision waiting for the owner.
        } else if let step = stepUnderWay {
            activity.update { $0.phase = .working; $0.headline = step.summary; $0.since = step.started; $0.runnerPaused = false }
        } else if !status.isRunning {
            activity.update { $0.phase = .idle; $0.headline = status.title }
        } else if activity.state.phase == .problem || activity.state.phase == .idle || activity.state.headline == "Starting the runner" || activity.state.headline == "Starting native services" {
            activity.update { $0.phase = .idle; $0.headline = "Waiting for agent" }
        }
    }

    private func handle(_ event: ShellEvent) {
        if case .approvalRequested(let approval) = event, let probe = onProbeApproval { probe(approval) }
        // Every outside agent's session and step goes into the Sessions list, on or off.
        SessionStore.shared.observe(event, approvals: approvals)
        // The first agent through a connector names it (unless the owner did) and gives it its icon.
        if case .session(.started(_, let client, _, let connector?)) = event {
            identity.noteAgent(hash: connector, client: AgentName.pretty(client))
        }
        // Events after Turn off (the core's own "stopped") are not for the screen. An approval is
        // the exception: a call that asks one (the on-device chat, the gym probe) waits on the
        // owner's answer whether or not Poki is on, and dropping it left that call waiting for the
        // whole approval time.
        switch event {
        case .approvalRequested, .approvalEnded: break
        default: guard sessionOn || probeDriven else { return }
        }
        for observer in shellObservers { observer(event) }
        switch event {
        case .session: break
        case .relay(let status):
            if status != relayStatus { log.add("relay", "\(status)") }
            relayStatus = status
        case .toolStarted(_, let summary, _):
            lastAgentActivity = Date(); lastStepAt = Date()
            stepUnderWay = (summary, Date())
            activityText = summary
            log.add("agent", "started: \(summary)")
            if problem?.hasPrefix("An approval ran out") == true { problem = nil }
            let caller = currentCaller
            if activity.state.agentTask?.background != true || activity.state.agentTask?.active != true {
                activity.stepStarted(StepLabels.withoutTypedText(summary))
                activity.update { state in
                    if state.agentTask?.active == false {
                        state.agentTask = nil; state.snapshotID = nil; state.snapshotAt = nil; state.thumbnailVersion = 0
                    }
                    if state.approval == nil {
                        if state.phase != .working || state.since == nil { state.since = Date() }
                        state.phase = .working
                    }
                    state.headline = summary
                    state.caller = caller
                }
            }
        case .toolFinished(let summary, let delivery, let app, let thumbnail, let error, _):
            lastAgentActivity = Date(); lastStepAt = Date()
            stepUnderWay = nil
            lastAction = "\(summary) · \(delivery)"
            activityText = "Idle"
            let failed = delivery.hasPrefix("failed")
            log.add("agent", "\(failed ? "failed" : "done"): \(summary) · \(delivery.prefix(160))" + (error.map { " · \($0)" } ?? ""))
            if let app { currentApp = app }
            recentSteps.append(RecentStep(text: summary, app: app, failure: failed ? delivery : nil, at: Date()))
            // The owner's own record of every action, with the run it came from.
            let chat = AskPoki.chat
            ActionLog.shared.add(summary, app: app, ok: !failed,
                                 session: SessionStore.shared.activeSessionID ?? (chat?.running == true ? chat?.sessionID : nil),
                                 caller: currentCaller)
            if recentSteps.count > 20 { recentSteps.removeFirst(recentSteps.count - 20) }
            if activity.state.agentTask?.background != true || activity.state.agentTask?.active != true {
                activity.record(step: StepLabels.withoutTypedText(summary), ok: !failed)
                activity.update { state in state.app = app ?? state.app }
                activity.setThumbnail(thumbnail)
            }
        case .approvalRequested(let approval) where ApprovalClassifier.isOn:
            // The chat model decides, out of sight: no Live Activity card, no notification, no tap.
            approvals.append(approval)
            log.add("approval", "requested \(approval.id) in \(approval.app): \(approval.summary); asking the auto-classifier")
            Task { [weak self] in
                let verdict = await ApprovalClassifier.decide(approval, level: ApprovalClassifier.Level.saved, voice: self?.voice.lines ?? [])
                guard let self else { return }
                self.log.add("approval", "auto-classifier \(verdict.allowed ? "allowed" : "refused") \(approval.id): \(verdict.reason)")
                self.core.resolveApproval(id: approval.id, approved: verdict.allowed)
            }
        case .approvalRequested(let approval):
            approvals.append(approval)
            log.add("approval", "requested \(approval.id) in \(approval.app): \(approval.summary); Live Activity \(activity.isRunning ? "running" : "NOT running: \(activity.lastError ?? "no error")")")
            let caller = currentCaller
            activity.update { $0.phase = .approval; $0.approval = approval; $0.headline = "Allow this step?"; $0.caller = caller }
            // The Live Activity pops up for it by itself; the notification is for when it is not running.
            // Before iOS 26 an approval is answered from the notification (touch and hold it); later, from
            // the Live Activity's own buttons when one is running.
            if #available(iOS 26.0, *), activity.isRunning {} else { ApprovalNotice.post(approval, caller: caller) }
        case .approvalEnded(let id, let approved):
            lastApprovalAnswered = Date()
            approvals.removeAll { $0.id == id }
            log.add("approval", "ended \(id): \(approved.map { $0 ? "approved" : "denied" } ?? "expired or replaced")")
            if approved == nil, !ApprovalClassifier.isOn { problem = "An approval ran out before you answered, so that step was not done. The agent can ask again." }
            ApprovalNotice.clear(id)
            activity.update { state in
                if state.approval?.id == id { state.approval = nil; state.phase = .working; state.headline = approved == true ? "Continuing" : "Step skipped" }
            }
        case .handoffRequested(let id, let kind, let text, let app):
            lastAgentActivity = Date(); lastStepAt = Date()
            let shown = PokiActivityAttributes.Handoff.Kind(rawValue: kind) ?? .other
            handoffText = text ?? Self.handoffWording(shown)
            log.add("handoff", "the agent handed over \(id) (\(kind))\(app.map { " in \($0)" } ?? ""): \(handoffText ?? "")")
            activity.update { state in
                state.phase = .handoff
                state.handoff = .init(id: id, kind: shown, text: text, app: app, since: Date())
                state.headline = "Your turn"
                state.app = app ?? state.app
            }
        case .handoffEnded(let id, let how):
            lastAgentActivity = Date(); lastStepAt = Date()
            log.add("handoff", "ended \(id): \(how)")
            handoffText = nil
            activity.update { state in
                if state.handoff?.id == id {
                    state.handoff = nil
                    state.phase = .working
                    state.headline = how == "done" ? "Carrying on" : "The agent carried on by itself"
                }
            }
        }
    }

    // MARK: The chat's tools

    /// A tool call from the chat's model loop. Poki turns on first when it is off (the runner then starts
    /// on this call, like for an agent's first request); when it cannot, the answer says why.
    /// The chat's turn ended: the phone goes back to the app the task began in, and the log says how.
    func finishTask() {
        Task { [core, log] in if let line = await core.finishTask() { log.add("runner", line) } }
    }

    func runTool(_ name: String, arguments: String) async -> PokiCore.ToolAnswer {
        if name == "look" || name == "do" { requestAutomationForTask("a phone tool") }
        if probeDriven { return await core.callTool(name, arguments: arguments) }
        if !sessionOn { startSession() }
        guard sessionOn else {
            let why = problem ?? "Poki is off."
            return PokiCore.ToolAnswer(text: "not_sent: Poki could not turn on: \(why) Nothing was sent. Tell the owner what to fix.", jpeg: nil, isError: true)
        }
        lastAgentActivity = Date(); lastStepAt = Date()
        return await core.callTool(name, arguments: arguments)
    }

    // MARK: Approvals

    /// Approvals from the app's own screen (the same path as the Live Activity's buttons).
    func resolve(_ approval: PendingApproval, approved: Bool) {
        core.resolveApproval(id: approval.id, approved: approved)
    }

    private func listenForApprovals() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.drainApprovals() }
        }, ApprovalMailbox.notification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.stopAgentFromLiveActivity() }
        }, ApprovalMailbox.stopRunner as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.handoffDone() }
        }, ApprovalMailbox.handoffDone as CFString, nil, .deliverImmediately)
    }

    /// The person tapped "Done, carry on" on the Live Activity's "Your turn" card.
    func handoffDone() {
        guard let id = ApprovalMailbox.drainHandoffDone() else { return }
        log.add("handoff", "done by the owner: \(id)")
        if id == Self.runnerPasscodeHandoff {
            // The runner's own launch: the launcher notices by itself when the runner answers.
            activity.update { $0.handoff = nil; $0.phase = runner.isRunning ? .idle : .working; $0.headline = runner.isRunning ? "Ready for the agent" : "Starting the runner" }
        } else {
            activity.update { $0.handoff = nil; $0.phase = .working; $0.headline = "Carrying on" }
            core.handoffDone(id: id)
        }
    }
    static let runnerPasscodeHandoff = "runner-passcode"

    /// What the owner is asked to do, when the model gave no words of its own.
    static func handoffWording(_ kind: PokiActivityAttributes.Handoff.Kind) -> String {
        switch kind {
        case .runnerPasscode: "The phone asks for your passcode so the runner can start"
        case .automationPasscode: "The phone asks for your passcode to allow automation"
        case .passcode: "The screen asks for your passcode"
        case .password: "The screen asks for a password"
        case .verification: "The screen asks for a verification step"
        case .payment: "The screen asks you to confirm a payment"
        case .other: "The agent cannot act on this screen; please do this step"
        }
    }

    /// Decisions an intent left in the App Group mailbox because it ran outside the app.
    func drainApprovals() {
        for decision in ApprovalMailbox.drain() { decide(decision) }
    }

    /// A decision from the Live Activity. The card shows the answer at once (Allowing, Denying).
    /// Allow is tapped on the expanded Dynamic Island, which takes about a second to collapse; input
    /// sent at once can land on it (iOS then opens Poki). So the Live Activity's decisions reach
    /// PokiCore after a short pause, the app's own buttons at once.
    func decide(_ decision: ApprovalDecision) {
        // A tap on an approval that already ended (answered in the app, or timed out) does nothing.
        guard approvals.contains(where: { $0.id == decision.approvalID }) else { return }
        log.add("approval", "\(decision.approved ? "allowed" : "denied") \(decision.approvalID) on the Live Activity")
        activity.update { state in
            guard state.approval?.id == decision.approvalID else { return }
            state.phase = .deciding
            state.decision = decision.approved
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.islandCollapse))
            core.resolveApproval(id: decision.approvalID, approved: decision.approved)
        }
    }

    /// How long the expanded island takes to fold after a tap on its button.
    static let islandCollapse: TimeInterval = 1.5

    /// A launcher failure as the Live Activity's content line, in English (the face words it in the
    /// system's language). The codes the launcher sends (native/launcher/src/device.rs, ddi.rs,
    /// launch.rs) have names of a few words; a failure without one gives the first part of its fix.
    /// What to do is in the app, which shows the whole fix.
    nonisolated static func problemText(code: String?, fix: String) -> String {
        let short = [
            "loopback": "Loopback Off",
            "network": "No Internet",
            "ddi_timeout": "No Internet",
            "ddi_refused": "Disk Image Outdated",
            "ddi_bad": "Fetching Disk Image",
            "pairing": "Pairing Refused",
            "handshake": "Loopback or Pairing",
            "unreachable": "Can’t Reach iPhone",
            "developer_mode": "Developer Mode Off",
            "no_cryptexd": "Check Developer Mode",
            "ios_too_old": "Update iOS",
            "runner": "Poki Runner Missing",
            "runner_blocked": "Poki Runner Didn’t Start",
        ]
        return code.flatMap { short[$0] } ?? firstPart(fix)
    }

    /// A text up to its first colon or the end of its first sentence, capitalised.
    nonisolated static func firstPart(_ text: String) -> String {
        let mark = [": ", ". "].compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let part = mark.map { String(text[..<$0.lowerBound]) } ?? text
        return part.prefix(1).uppercased() + part.dropFirst()
    }

    // MARK: Pairing

    func importPairingFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try importPairingFile(try Data(contentsOf: url), how: "imported")
    }

    /// A pairing file as bytes: from Files, AirDrop, a `poki://pairing` link or Poki Setup on a computer.
    func importPairingFile(_ data: Data, how: String) throws {
        // A lockdown pairing plist or an RPPairing file; both are property lists.
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
        try data.write(to: AppFiles.pairingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Chosen by hand: it replaces the phone's own pairing as well.
        try? FileManager.default.removeItem(at: AppFiles.phonePairingFile)
        pairingFileSeen = true
        SetupVault.storePairing(data)
        setup.pairingFile = AppFiles.pairingFile.path
        pairingTrouble = nil; pairingVerifiedAt = nil
        pairingNote = String(localized: "Pairing file received.")
        log.add("pairing", "pairing file \(how)")
    }

    /// What the last pairing link or file did, for the pairing page.
    var pairingNote: String?

    /// A link Poki was opened with. `poki://pairing?url=…[&sha256=…]` fetches a pairing file (Poki
    /// Setup serves it on the local network and shows the link as a code); `poki://pairing?data=…`
    /// carries one in base64url; `poki://setup?relay=…` sets the relay. A file URL is a pairing file
    /// opened from AirDrop or Files. Returns the setup step to show, or nil when the link was none of these.
    func open(link url: URL) -> SetupStep? {
        if url.isFileURL {
            do { try importPairingFile(from: url) } catch { pairingNote = String(localized: "Invalid Pairing File: \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: url)
            return .pairing
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host() {
        case "pairing":
            if let text = item("data"), let data = Data(base64URL: text) {
                do { try importPairingFile(data, how: "received by link") } catch { pairingNote = String(localized: "Invalid Pairing File: \(error.localizedDescription)") }
            } else if let from = item("url").flatMap(URL.init(string:)), ["http", "https"].contains(from.scheme ?? "") {
                let expected = item("sha256")?.lowercased()
                pairingNote = String(localized: "Fetching the pairing file from \(from.host() ?? "your computer")…")
                Task {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: from)
                        if let expected, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != expected {
                            throw NSError(domain: "poki", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "the file does not match the link")])
                        }
                        try importPairingFile(data, how: "fetched from \(from.host() ?? "?")")
                    } catch { pairingNote = String(localized: "Could not get the pairing file: \(error.localizedDescription)") }
                }
            } else {
                pairingNote = String(localized: "The pairing link carried no file.")
            }
            return .pairing
        case "setup" where item("step") != nil:
            // The Live Activity's link to a setup step (pairing).
            return item("step").flatMap(SetupStep.init(rawValue:))
        case "setup":
            // Poki Setup hands over the relay it configured (the Cloudflare proxy); the chat shows it.
            if let relay = item("relay") { log.add("relay", setRelay(relay) ? "set by link" : "link carried no relay address") }
            return nil
        default: return nil
        }
    }

    func startPairing() {
        guard loopback.isWorking else {
            pairing = .failed("Enable a local connection in Setup and wait for the connection check to pass, then try pairing again.")
            return
        }
        pairing = .advertising
        // The code also comes as a banner (PairingNotice): ask for notifications now, while in front.
        ApprovalNotice.requestPermission()
        // Started now, while Poki is in front: the PIN arrives while the person is in Settings, when
        // iOS no longer lets Poki start a Live Activity.
        activity.start(deviceName: deviceName)
        activity.update { $0.phase = .pairing; $0.pin = nil; $0.headline = "Pair in Settings" }
        // The person completes pairing in Settings. Keep the listener and Bonjour publication alive
        // there, before a regular Poki session can be started. Without it (audio can be busy, as in a
        // call) pairing still starts, as it did before the keep-alive.
        // Location keeps Poki running in Settings as well (While Using is enough, started here in front).
        background.holdForPairing()
        log.add("pairing", "staying on with location (\(background.allowed ? "allowed" : "not allowed yet")) and silent audio")
        do { try pairingKeepAlive.start() }
        catch { log.add("pairing", "keep-alive did not start (\(error.localizedDescription)); iOS may stop the pairing while Settings is open") }
        do {
            try pairer.start(hostName: "Poki", saveTo: AppFiles.pairingFile) { [weak self] event in
                Task { @MainActor in self?.pairingChanged(event) }
            }
        } catch { pairingChanged(.failed("\(error)")) }
    }

    func cancelPairing() {
        if pairingUnderWay { log.add("pairing", "stopped") }
        pairer.cancel()
        pairingKeepAlive.stop()
        background.releasePairing()
        pairing = nil
        activity.update { $0.pin = nil }
        if !sessionOn { stopGuide(); activity.end() }
    }

    /// Waiting for Settings or showing a PIN: the listener, Bonjour and the keep-alive are running.
    var pairingUnderWay: Bool {
        switch pairing {
        case .advertising?, .pin?: true
        default: false
        }
    }

    /// The person left the pairing step in Poki (another tab, or another step): the pairing stops at
    /// once, and with it the background keep-alive. Going to Settings is not leaving.
    func leftPairing() {
        guard pairingUnderWay else { return }
        // Only a move inside Poki counts. iOS can take pages down while Poki is in the background
        // (the person is in Settings typing the code) or while it comes back; that is not leaving.
        guard inFront, UIApplication.shared.applicationState == .active, Date().timeIntervalSince(cameToFront) > 2 else {
            log.add("pairing", "pairing page went away while Poki was not in front; the pairing goes on")
            return
        }
        log.add("pairing", "cancelled: the pairing step was left")
        cancelPairing()
    }

    private func pairingChanged(_ event: PairingEvent) {
        pairing = event
        switch event {
        case .pin(let pin):
            // The PIN goes in the Live Activity, so it is visible while the user is in Settings.
            activity.start(deviceName: deviceName)
            activity.update { $0.phase = .pairing; $0.pin = pin; $0.headline = "Pairing code" }
            // A banner with the code as well: it drops down over Settings by itself, also when the Live
            // Activity is off, was dismissed, or iOS holds back its alert.
            PairingNotice.post(pin: pin)
            log.add("pairing", "code ready\(activity.isRunning ? "" : " (no Live Activity: \(activity.lastError ?? "unknown reason"))")")
        case .paired(let url):
            PairingNotice.clear()
            pairingKeepAlive.stop()
            background.releasePairing()
            try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
            setup.pairingFile = url.path
            if let data = try? Data(contentsOf: url) {
                SetupVault.storePairing(data)
                try? data.write(to: AppFiles.phonePairingFile, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            pairingTrouble = nil; pairingVerifiedAt = nil
            log.add("pairing", "paired on the phone")
            activity.update { $0.phase = .idle; $0.pin = nil; $0.headline = "Paired" }
            if !sessionOn { Task { try? await Task.sleep(for: .seconds(4)); if !self.sessionOn { self.activity.end() } } }
        case .failed(let why):
            PairingNotice.clear()
            pairingKeepAlive.stop()
            background.releasePairing()
            activity.update { $0.phase = .problem; $0.pin = nil; $0.label = "Pairing Failed"; $0.headline = Self.firstPart(why) }
            if !sessionOn { Task { try? await Task.sleep(for: .seconds(8)); if !self.sessionOn { self.activity.end() } } }
        case .advertising: break
        }
    }

    // MARK: Setup guide

    /// The person is going to Settings for a setup step: the Live Activity shows the step and what to
    /// tap, so it stays in view there. Ended when they come back and the step is done.
    func guide(_ step: SetupStep) {
        guiding = step
        guard !sessionOn else { return }
        activity.start(deviceName: deviceName)
        let steps = SetupStep.shown
        activity.update {
            $0.phase = .setup
            $0.headline = "Setting up Poki"
            $0.guide = .init(number: (steps.firstIndex(of: step) ?? 0) + 1, count: steps.count, title: step.activityTitle)
        }
    }

    func stopGuide() {
        guard guiding != nil else { return }
        guiding = nil
        activity.update { $0.guide = nil }
        if !sessionOn, activity.state.phase == .setup { activity.end() }
    }

    func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .runner: setup.runnerInstalled
        case .developerMode: setup.developerMode
        // A loopback that answers is the step done, whichever app provides it: one set up before Poki
        // (or by Poki Setup on a computer) has no row tapped here, and `loopbackChanged` records it.
        case .loopback: loopback.isWorking
        // The disk image downloads by itself (and is checked again when Poki turns on): it does not hold the step open.
        case .pairing: pairingPath != nil && pairingTrouble == nil
        case .automation: setup.uiAutomation
        case .background: background.allowed && activity.enabled
        }
    }

    var setupComplete: Bool { SetupStep.shown.allSatisfy(isDone) }

    /// A step as Home, the tab badge and the status pill show it: the loopback's first check after
    /// launch (a connection was chosen before) counts as done until it says otherwise, so Poki shows
    /// Ready rather than Paused and a warning for the second it takes. The Setup page keeps isDone.
    func looksDone(_ step: SetupStep) -> Bool {
        if step == .loopback, loopback.state == .checking, setup.loopback != .none { return true }
        return isDone(step)
    }
    var setupLooksComplete: Bool { SetupStep.shown.allSatisfy(looksDone) }

    /// A setup step is still to do. The loopback counts as done once a connection is chosen: whether it
    /// answers right now is checked live and is off whenever Poki is (the built-in connection), which is
    /// not a step left for the owner.
    var setupStepsLeft: Bool {
        SetupStep.shown.contains { $0 == .loopback ? setup.loopback == .none : !isDone($0) }
    }

    var activityProblem: String? { activity.lastError }
    var activitiesEnabled: Bool { activity.enabled }

    // MARK: Relay and connectors

    static let noRelay = "Enter your relay's address first (Settings › Relay). Poki has no default relay."

    /// Saves the relay address the person entered; false when it is not one. A running session moves
    /// to the new relay at once.
    func setRelay(_ text: String) -> Bool {
        guard let address = RelayAddress(text) else { return false }
        guard address != relayAddress else { return true }
        RelayAddress.saved = address
        let first = relayAddress == nil
        relayAddress = address
        log.add("relay", "address set to \(address.origin.host() ?? "?")")
        if problem == Self.noRelay { problem = nil }
        // A relay just set is on.
        if first || !relayEnabled { relayEnabled = true; UserDefaults.standard.set(true, forKey: "relayEnabled") }
        if sessionOn {
            core.stop()
            core.start(relay: address)
        }
        return true
    }

    /// The MCP address for a connector, on the person's relay; nil until a relay is set.
    func connectorURL(for secret: ConnectorSecret) -> URL? {
        relayAddress.map { identity.url(for: secret, relay: $0) }
    }

    func addConnector(name: String) -> ConnectorSecret {
        let secret = identity.addSecret(name: name)
        accessChanged()
        return secret
    }
    func revoke(_ secret: ConnectorSecret) { identity.revoke(secret); accessChanged() }
    func rename(_ secret: ConnectorSecret, to name: String) { identity.rename(secret, to: name) }
    private func accessChanged() {
        host.update(key: identity.signingKey, hashes: identity.accessHashes)
        core.accessChanged()
    }
}

/// Whether WebDriverAgent answers /status right now (2 s at most).
enum RunnerProbe {
    /// Asks the runner to shut itself down: it ends its test and exits, which takes the automation
    /// banner with it. Nothing happens when it is not running.
    static func shutdown() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        func send(_ method: String, _ path: String) async -> Data? {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8100\(path)")!, timeoutInterval: 2)
            request.httpMethod = method
            return try? await session.data(for: request).0
        }
        // The shutdown request waits in WDA's queue behind a slow tree read; ending the session first
        // voids whatever is queued, so the shutdown is handled at once.
        if let status = await send("GET", "/status"),
           let json = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
           let id = json["sessionId"] as? String, !id.isEmpty {
            _ = await send("DELETE", "/session/\(id)")
        }
        _ = await send("GET", "/wda/shutdown")
    }

    static func answers() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8100/status")!, timeoutInterval: 2)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        guard let (_, response) = try? await URLSession(configuration: configuration).data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// When this iPhone last started (kern.boottime, seconds): iOS asks for the passcode before the first
/// automation after each start.
enum BootClock {
    static let current: Double = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Double(boot.tv_sec)
    }()
}
