import AppKit
import CoreAudio
import ServiceManagement

// 앱 수명 관리: 메뉴바 항목, Core Audio 리스너, 장치 변경 재생성, 종료 신호, 로그인 항목

// 로그인 항목 등록·해제. 앱 폴더 안의 실행 파일로 불러야 동작한다. 실패하면 오류를 돌려준다.
func setLogin(_ enabled: Bool) -> Error? {
    do {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return nil
    } catch {
        return error
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let mixer: Mixer
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var signalSources: [DispatchSourceSignal] = []
    // 받은 종료 신호 수. signalQueue 에서만 읽고 쓴다
    var signalCount = 0
    let signalQueue = DispatchQueue(label: "app-volume.signal")

    init(mixer: Mixer) {
        self.mixer = mixer
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = mixerIcon()
        menu.delegate = self
        statusItem.menu = menu
        mixer.refresh()

        // 프로세스 목록이 바뀌면 바로 반응한다. 새 프로세스에 곧바로 탭을 걸지만 첫 소리보다 먼저라는 보장은 없다.
        listen(kAudioHardwarePropertyProcessObjectList) { [mixer] in mixer.refresh() }
        // 기본 출력 장치가 바뀌면(블루투스 연결·해제 등) 탭을 새 장치로 다시 만든다
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [mixer] in mixer.restartSoon() }
        // 리스너와 별도로 1초마다 돈다. 탭을 못 만든 프로세스의 재시도와
        // 이미 끝났지만 목록에 남아 있던 프로세스가 빠지는 것을 리스너가 놓친 경우를 챙긴다.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [mixer] _ in mixer.refresh() }

        // 터미널의 kill·Ctrl-C·창 닫기로 꺼도 메뉴의 「종료」처럼 탭을 정리하고 끝낸다.
        // nohup 처럼 이미 무시하게 해 둔 신호는 그대로 무시한다. 메인 스레드가 막혀 정리가 안 되면 두 번째 신호에 바로 끝낸다.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            // 함수 포인터는 == 로 비교할 수 없어 주소값으로 비교한다
            let previous = signal(number, SIG_IGN)
            if unsafeBitCast(previous, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) { continue }
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.signalCount += 1
                if self.signalCount >= 2 { exit(1) }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = globalAddress(selector)
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main) { _, _ in handler() }
        if status != noErr {
            NSLog("app-volume: 리스너 등록 실패 (속성 %u, 코드 %d)", selector, status)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.stopAll()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        mixer.refresh()
        menu.removeAllItems()

        var names: [String: String] = [:]
        for process in mixer.processes where names[process.key] == nil && mixer.isListed(process) {
            names[process.key] = appName(process.key)
        }
        let keys = names.keys.sorted { names[$0]! < names[$1]! }

        if keys.isEmpty {
            let empty = NSMenuItem(title: "지금 소리를 내는 앱이 없다", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for key in keys {
            let item = NSMenuItem()
            item.view = RowView(key: key, name: names[key]!, mixer: mixer)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "로그인할 때 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleLogin() {
        // 등록은 됐는데 사용자 승인이 남았으면 다시 등록하지 않고 승인할 곳(시스템 설정의 로그인 항목)을 연다
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        // 메뉴바 앱이라 print 가 보이지 않으므로 실패하면 알림창으로 알린다
        if let error = setLogin(SMAppService.mainApp.status != .enabled) {
            let alert = NSAlert()
            alert.messageText = "로그인 항목을 바꾸지 못했다"
            alert.informativeText = "\(error.localizedDescription)\n\n앱 폴더(app-volume.app) 안의 실행 파일로 켰을 때만 동작한다."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
