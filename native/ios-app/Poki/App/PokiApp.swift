import PokiCore
import SwiftUI

@main
struct PokiApp: App {
    @State private var model: AppModel
    @State private var chat: ChatModel

    init() {
        // PokiLauncher (Rust) and the relay write to sockets the other side may have closed. In an app,
        // unlike a Rust executable, nothing ignores SIGPIPE, and it would end the whole app.
        signal(SIGPIPE, SIG_IGN)
        // iOS 26: the background task that keeps Poki up is registered before launch ends, as iOS asks.
        if #available(iOS 26.0, *) { ContinuedRun.registerAtLaunch() }
        // Settings an update, a reinstall or a re-sign lost come back from the Keychain, before anything
        // reads them; from here on every change is mirrored there.
        SettingsVault.restore()
        SettingsVault.watch()
        // Page titles in Geist, the website's typeface (prominent text only).
        if let large = Prominent.uiFont(.largeTitle, .bold), let inline = Prominent.uiFont(.headline, .semibold) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: large]
            UINavigationBar.appearance().titleTextAttributes = [.font: inline]
        }
        // The tab bar's attention dots (Setup items open, Agents trouble) are orange, the warning colour.
        UITabBarItem.appearance().badgeColor = .systemOrange
        #if DEBUG && targetEnvironment(simulator)
        TestCredential.importIfGiven()
        #endif
        // A memory backup Poki Setup put back (Documents/AgentBackup) is merged in before any agent asks.
        _ = RoutineStore.shared.importRestoredBackup()
        let model = AppModel()
        _model = State(initialValue: model)
        let chat = ChatModel(app: model)
        _chat = State(initialValue: chat)
        AskPoki.install(app: model, chat: chat)
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(model).environment(chat)
        }
    }
}

/// Two tabs, as a native iPhone app has them: Chats (the Sessions list, Poki's chat and an agent's session
/// over it, like Messages) and Status (Poki's run status, model, history and settings). Voice lives inside
/// the chat: a live conversation button and dictation into the message field.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = RootTab.chats
    @State private var home = NavigationPath()
    /// The Agents and Setup tabs' pages, pushed; nothing is an overlay.
    @State private var agents = NavigationPath()
    @State private var setup = NavigationPath()

    /// Sessions is the first page; Poki's chat and an agent's session open over it, like a conversation
    /// in Messages; setup's checklist and its items are pushed there too.
    enum HomeRoute: Hashable { case chat, session(String), setup }
    enum RootTab: Hashable { case chats, agents, setup, newChat }

    @Environment(\.horizontalSizeClass) private var width
    /// In a wide window (iPad, the inner display of iPhone Duo, a large Split View or Stage Manager
    /// window) the Poki tab is split: sessions and controls on the left, the chat on the right.
    @State private var wide: HomeRoute = .chat
    /// The tab bar leaves while a conversation is open on iPhone. It is set here, on the stack, and
    /// changed inside an animation, so it eases out on the way in and eases back in on the way out
    /// (a hidden tab bar set by the pushed page itself snaps).
    @State private var tabBarHidden = false

    private func show(_ route: HomeRoute) {
        wide = route
        home = NavigationPath([route])
        setTabBarHidden(route != .setup && width != .regular)
    }

    private func setTabBarHidden(_ hidden: Bool) {
        guard hidden != tabBarHidden else { return }
        withAnimation(.easeInOut(duration: 0.3)) { tabBarHidden = hidden }
    }

    private var sessions: some View {
        SessionsView(openChat: { show(HomeRoute.chat) }, openSession: { show(HomeRoute.session($0)) },
                     openModel: { openAgents(AgentsRoute.accounts) },
                     openConnectors: { tab = .agents; agents = NavigationPath() },
                     openDetails: { tab = .agents }, openVoice: openLiveVoice,
                     openSetup: { tab = .setup; setup = NavigationPath() })
    }

    @ViewBuilder private func page(_ route: HomeRoute, split: Bool) -> some View {
        switch route {
        case .chat:
            ChatView(openDetails: { tab = .agents }, openVoice: openLiveVoice,
                     openSetup: openSetup, openModel: { openAgents(AgentsRoute.accounts) },
                     back: split ? nil : { home = NavigationPath() })
        case .session(let id):
            SessionView(id: id, back: { home = NavigationPath() })
        case .setup:
            SetupChecklist()
        }
    }

    @ViewBuilder private var pokiTab: some View {
        if width == .regular {
            NavigationSplitView {
                sessions
                    .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
            } detail: {
                NavigationStack {
                    page(wide, split: true).id(wide)
                        .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: $home) {
                sessions
                    .navigationDestination(for: HomeRoute.self) { page($0, split: false) }
                    .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
            }
            .toolbarVisibility(tabBarHidden ? .hidden : .visible, for: .tabBar)
            // Back (the button or the edge swipe) empties the path: the tab bar eases back in.
            .onChange(of: home.isEmpty) { _, empty in if empty { setTabBarHidden(false) } }
        }
    }

    // Keep the tab content and alert chains in separate expressions for Xcode 26.2's type checker.
    private var tabs: some View {
        TabView(selection: $tab) {
            Tab(String(localized: "Poki"), systemImage: "bubble.left.and.bubble.right.fill", value: RootTab.chats) { pokiTab }

            Tab("Agents", systemImage: "point.3.connected.trianglepath.dotted", value: RootTab.agents) {
                AgentsView(path: $agents, openSession: openRun)
            }
            // A dot when something there needs attention: no account for the chat, or the relay down.
            .badge(agentsNeedAttention ? Text(verbatim: " ") : nil)

            Tab("Setup", systemImage: "checklist", value: RootTab.setup) { SetupTab(path: $setup) }
                // A dot while a setup item is still open.
                .badge(model.setupLooksComplete ? nil : Text(verbatim: " "))

            // iOS 26: New Chat is the round button at the bottom right, on the tab bar's line (the
            // place iOS gives a search tab). Choosing it starts a chat and goes back to the Poki tab.
            if #available(iOS 26.0, *) {
                Tab(String(localized: "New Chat"), systemImage: "square.and.pencil", value: RootTab.newChat, role: .search) { Color.clear }
            }
        }
    }

    private var navigation: some View {
        tabs
        .onChange(of: tab) { old, new in
            // Leaving the Poki tab from a conversation (to Accounts, Setup, a connector): the Poki
            // tab is back at Sessions, with its tab bar, when you come back. Done without animation
            // while the other tab is in front, so nothing flashes and the tab bar is laid out afresh.
            if old == .chats, new != .chats, new != .newChat, width != .regular, !home.isEmpty {
                var quiet = Transaction(); quiet.disablesAnimations = true
                withTransaction(quiet) { home = NavigationPath(); tabBarHidden = false }
            }
            guard new == .newChat else { return }
            tab = .chats
            if !chat.running { chat.newConversation() }
            show(HomeRoute.chat)
        }
        .task { InProcessProbe.shared.startFromLaunchArguments(model: model) }
    }

    private var connectionAlerts: some View {
        navigation
        .alert(model.connectionAsk.map { String(localized: "Allow \($0.client) to connect?") } ?? "",
               isPresented: Binding(get: { model.connectionAsk != nil }, set: { if !$0 { model.answerConnection(false) } }),
               presenting: model.connectionAsk) { _ in
            Button("Don’t Allow", role: .cancel) { model.answerConnection(false) }
            Button("Allow") { model.answerConnection(true) }
        } message: { ask in
            Text("\(ask.client) is signing in through \(ask.connector) and returns to \(ask.callback), which isn’t on Poki’s list of known agents. Allow it only if you are connecting it yourself right now. It could then see your screen and act on this iPhone.")
        }
        // The update's last step: Poki has to exit, and the owner closes it from the app switcher.
        .alert("Poki Will Close to Finish the Update", isPresented: Binding(get: { model.signer.finishNotice }, set: { if !$0 { model.signer.finishNoticeAnswered() } })) {
            Button("OK") { model.signer.finishNoticeAnswered() }
        } message: {
            Text("The update is almost in. Poki will close to finish it; open Poki again afterwards.")
        }
    }

    private var automationAlerts: some View {
        connectionAlerts
        // Turning on after Off: Poki exits by itself and has to be opened again.
        .alert("Poki Restarts to Turn On", isPresented: Binding(get: { model.relaunchNotice }, set: { if !$0 { model.relaunchNotice = false } })) {
            Button("Cancel", role: .cancel) { model.relaunchNotice = false }
            Button("Continue") { model.continueRelaunch() }
        } message: {
            Text("Poki closes by itself so agents can see the screen again. Open Poki again afterwards, from the notification or the Home Screen; it turns on when it opens.")
        }

    }

    var body: some View {
        automationAlerts
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.becameActive(); AskPoki.refresh(); model.startSigner(); model.signer.maintain(); Task { await model.verifyPairing() } } else if phase == .background { model.wentToBackground() }
        }
        // A tap on the Live Activity opens the screen its state is about (ActivityFace.link): the chat,
        // the setup step, or the Activity Log for a problem; `poki://voice` opens the chat too (it
        // never turns on the microphone).
        .onOpenURL { url in
            AppLog.shared.add("app", "opened by link poki://\(url.host() ?? "")")
            // Pairing is not interrupted: it stays on the pairing step, where the PIN is.
            guard !model.pairingUnderWay else { return }
            // A pairing file or a setup link (from Poki Setup on a computer, AirDrop or Files) opens
            // setup at that step, where the result is shown.
            if let step = model.open(link: url) {
                tab = .setup
                setup = NavigationPath([step])
            } else if url.host() == "setup", !url.absoluteString.contains("relay=") {
                // The Live Activity during setup: the Setup tab.
                tab = .setup
            } else if url.host() == "log" {
                // The Live Activity's problem: what went wrong is in the Activity Log.
                openAgents(.activityLog)
            } else {
                if url.host() == "voice" { model.voice.open(url) }
                tab = .chats; show(HomeRoute.chat)
            }
        }
        .onAppear(perform: openLaunchScreen)
        .task {
            #if DEBUG
            // Development builds: `-pokiVoiceLink "poki://voice?…"` at launch starts a silent test run.
            if let link = UserDefaults.standard.string(forKey: "pokiVoiceLink"), let url = URL(string: link), url.host() == "voice" {
                tab = .chats; show(HomeRoute.chat)
                model.voice.openAtLaunch(url)
            }
            #endif
        }
    }

    /// The Agents tab needs a look: no usable chat account, or the relay set but not reachable.
    private var agentsNeedAttention: Bool {
        if !ModelKeys.hasUsableKey { return true }
        if case .offline = model.relayStatus { return true }
        return false
    }

    /// A page of the Agents tab: accounts, voice, the Activity Log.
    private func openAgents(_ route: AgentsRoute) {
        tab = .agents
        agents = NavigationPath([route])
    }

    /// The live voice conversation runs inside Poki's chat: the chat opens and the conversation starts.
    private func openLiveVoice() {
        tab = .chats
        show(HomeRoute.chat)
        if !model.voice.isOn, model.voice.canTalkLive {
            // Taps that send, pay, delete or call ask for the person's OK, also by notification.
            ApprovalNotice.requestPermission()
            Task { await model.voice.start() }
        }
    }

    /// Setup's checklist, on the Chats page.
    private func openSetup() {
        tab = .chats
        show(HomeRoute.setup)
    }

    /// A run from the Activity Log: Poki's own chat or an outside agent's session, in Chats.
    private func openRun(_ id: String) {
        tab = .chats
        if let session = SessionStore.shared.session(id), session.kind == .poki {
            if session.id != chat.sessionID { chat.restore(session) }
            show(HomeRoute.chat)
        } else {
            show(HomeRoute.session(id))
        }
    }


    /// `-pokiScreen setup` (connect, debug, activity, details, model, voice…) opens that screen at launch,
    /// for the build's screenshots; `-pokiSetupStep 3` opens setup at that step.
    private func openLaunchScreen() {
        let defaults = UserDefaults.standard
        // `-pokiVoiceBridge <address>`: the voice bridge address, from the Mac that launches the app (only a
        // developer connection can pass launch arguments). It never turns on the microphone.
        if let address = defaults.string(forKey: "pokiVoiceBridge") { _ = model.voice.setBridge(address) }
        // A sample conversation (`-pokiChat working`) opens in the chat itself.
        if defaults.string(forKey: "pokiChat") != nil { show(HomeRoute.chat) }
        switch defaults.string(forKey: "pokiScreen") {
        case "chat": show(HomeRoute.chat)
        case "session": if let first = SessionStore.shared.ordered.first(where: { $0.kind == .agent || $0.kind == .handoff }) { show(HomeRoute.session(first.id)) }
        case "setup":
            let step = defaults.integer(forKey: "pokiSetupStep")
            tab = .setup
            setup = step > 0 ? NavigationPath([SetupStep.shown[min(step, SetupStep.shown.count) - 1]]) : NavigationPath()
        case "connect", "settings": tab = .agents
        case "debug": tab = .setup; setup = NavigationPath([SettingsRoute.diagnostics])
        case "activity": tab = .setup; setup = NavigationPath([SettingsRoute.diagnostics, SettingsRoute.activityPreview])
        case "connector":
            tab = .agents
            if let first = model.identity.secrets.first { agents = NavigationPath([SettingsRoute.connector(first)]) }
        case "details", "status": tab = .agents
        case "model": openAgents(.accounts)
        case "steps": openAgents(.activityLog)
        case "voice": show(HomeRoute.chat)
        default: break
        }
    }
}
