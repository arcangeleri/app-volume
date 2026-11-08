import AppKit
import CoreAudio
import ServiceManagement

// 메뉴의 앱 한 줄: 이름, 볼륨 슬라이더, 퍼센트(또는 「음소거」·「실패」), 음소거 버튼
final class RowView: NSView {
    let key: String
    let mixer: Mixer
    let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let percent = NSTextField(labelWithString: "")
    let muteButton = NSButton()

    init(key: String, name: String, mixer: Mixer) {
        self.key = key
        self.mixer = mixer
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 46))

        let title = NSTextField(labelWithString: name)
        title.frame = NSRect(x: 14, y: 26, width: 250, height: 16)
        title.font = .systemFont(ofSize: 12)

        slider.frame = NSRect(x: 14, y: 4, width: 150, height: 20)
        slider.floatValue = mixer.effectiveGain(key)
        slider.target = self
        slider.action = #selector(changed)

        percent.frame = NSRect(x: 168, y: 6, width: 56, height: 16)
        percent.alignment = .right

        muteButton.frame = NSRect(x: 230, y: 3, width: 36, height: 22)
        muteButton.setButtonType(.toggle)
        muteButton.bezelStyle = .texturedRounded
        muteButton.imagePosition = .imageOnly
        muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "음소거")
        muteButton.alternateImage = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "음소거 해제")
        muteButton.state = mixer.muted.contains(key) ? .on : .off
        muteButton.target = self
        muteButton.action = #selector(muteToggled)
        updatePercent()

        addSubview(title)
        addSubview(slider)
        addSubview(percent)
        addSubview(muteButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updatePercent() {
        // 탭을 못 만들면 슬라이더 값과 달리 소리가 그대로 나므로 실패를 먼저 보여 준다
        if mixer.hasFailure(key) {
            percent.stringValue = "실패"
            percent.textColor = .systemRed
            percent.toolTip = "볼륨을 적용하지 못했다. 오디오 캡처 권한을 확인한다. \(Int(mixer.retryInterval))초마다 다시 시도한다."
            return
        }
        percent.textColor = .labelColor
        percent.toolTip = nil
        percent.stringValue = mixer.muted.contains(key) ? "음소거" : "\(Int((mixer.gain(key) * 100).rounded()))%"
    }

    // 한 줄을 조작해도 refresh 가 다른 앱의 탭 재시도 결과를 바꿀 수 있어 열린 메뉴의 모든 줄(이 줄 포함)을 갱신한다
    func updateAllRows() {
        for item in enclosingMenuItem?.menu?.items ?? [] {
            (item.view as? RowView)?.updatePercent()
        }
    }

    @objc func muteToggled() {
        mixer.setMuted(key, muteButton.state == .on)
        slider.floatValue = mixer.effectiveGain(key)
        updateAllRows()
    }

    @objc func changed() {
        mixer.setGain(key, slider.floatValue)
        muteButton.state = .off
        updateAllRows()
    }
}

// 메뉴바 아이콘: 이퀄라이저처럼 네모 막대가 쌓인 모양 (세로 3, 5, 4칸)
func mixerIcon() -> NSImage {
    let columnHeights = [3, 5, 4]
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        for (column, height) in columnHeights.enumerated() {
            for row in 0..<height {
                let rect = NSRect(x: 1.5 + CGFloat(column) * 5.5, y: 2 + CGFloat(row) * 3, width: 4.5, height: 2)
                NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
            }
        }
        return true
    }
    image.isTemplate = true
    return image
}

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
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [mixer] in mixer.restartAll() }
        // 리스너와 별도로 1초마다 돈다. 탭을 못 만든 프로세스의 재시도와
        // 이미 끝났지만 목록에 남아 있던 프로세스가 빠지는 것을 리스너가 놓친 경우를 챙긴다.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [mixer] _ in mixer.refresh() }

        // 터미널의 kill·Ctrl-C 로 꺼도 메뉴의 「종료」처럼 탭을 정리하고 끝낸다
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
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
