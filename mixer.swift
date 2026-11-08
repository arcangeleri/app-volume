import AppKit
import CoreAudio
import ServiceManagement

// 메뉴바 앱 믹서: 지금 소리를 내는 프로세스를 앱 단위 슬라이더로 보여 주고,
// 100% 미만으로 내린 앱에만 프로세스 탭을 걸어 볼륨을 곱해 기본 출력 장치로 다시 낸다.

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
}

struct AudioProcess {
    let object: AudioObjectID
    let pid: Int32
    let key: String
    let isOutputting: Bool
}

// 앱 단위로 묶는 키(번들 ID). 볼륨도 이 키로 저장한다. 크롬 같은 도우미 프로세스는 본체 번들 ID 로 합친다.
func appKey(bundleID: String, pid: Int32) -> String {
    if bundleID.isEmpty {
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid-\(pid)"
    }
    if let range = bundleID.range(of: ".helper", options: .caseInsensitive) {
        return String(bundleID[..<range.lowerBound])
    }
    return bundleID
}

func appName(_ key: String) -> String {
    if let name = NSRunningApplication.runningApplications(withBundleIdentifier: key).first?.localizedName {
        return name
    }
    return key.split(separator: ".").last.map(String.init) ?? key
}

func listProcesses() -> [AudioProcess] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else { return [] }

    var result: [AudioProcess] = []
    for object in objects {
        var pid: Int32 = 0
        var running: UInt32 = 0
        var bundleRef: Unmanaged<CFString>?
        _ = audioProperty(object, kAudioProcessPropertyPID, &pid)
        _ = audioProperty(object, kAudioProcessPropertyIsRunningOutput, &running)
        _ = audioProperty(object, kAudioProcessPropertyBundleID, &bundleRef)
        if pid == getpid() { continue }
        // 오디오 시스템이 닫힌 프로세스를 잠깐 더 들고 있어도 이미 끝난 pid 는 뺀다
        if kill(pid, 0) != 0 && errno == ESRCH { continue }
        let bundleID = bundleRef.map { $0.takeRetainedValue() as String } ?? ""
        result.append(AudioProcess(object: object, pid: pid, key: appKey(bundleID: bundleID, pid: pid), isOutputting: running != 0))
    }
    return result
}

// 프로세스 하나의 소리를 탭으로 잡아 원래 출력은 끄고, 볼륨을 곱해 기본 출력 장치로 다시 낸다.
final class Tap {
    var gain: Float
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?

    init?(processObject: AudioObjectID, gain: Float) {
        self.gain = gain

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = UUID()
        description.muteBehavior = .muted
        // 메뉴바 앱이라 print 는 보이지 않는다. 실패 원인은 NSLog 로 남겨 콘솔 앱에서 찾게 한다.
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            NSLog("app-volume: 탭 만들기 실패 (코드 %d)", tapStatus)
            return nil
        }

        // 효과음용 장치(DefaultSystemOutputDevice)가 아니라 소리 설정의 기본 출력 장치로 낸다
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        var uidRef: Unmanaged<CFString>?
        guard audioProperty(systemObject, kAudioHardwarePropertyDefaultOutputDevice, &outputDevice),
              audioProperty(outputDevice, kAudioDevicePropertyDeviceUID, &uidRef),
              let uid = uidRef?.takeRetainedValue() as String? else {
            NSLog("app-volume: 출력 장치 얻기 실패")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "app-volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            NSLog("app-volume: 집합 장치 만들기 실패 (코드 %d)", aggregateStatus)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let queue = DispatchQueue(label: "app-volume.io", qos: .userInteractive)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [unowned self] _, inData, _, outData, _ in
            let gain = self.gain
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let output = UnsafeMutableAudioBufferListPointer(outData)
            for index in 0..<min(input.count, output.count) {
                guard let source = input[index].mData, let destination = output[index].mData else { continue }
                let byteCount = Int(min(input[index].mDataByteSize, output[index].mDataByteSize))
                let from = source.assumingMemoryBound(to: Float.self)
                let to = destination.assumingMemoryBound(to: Float.self)
                for sample in 0..<(byteCount / MemoryLayout<Float>.size) {
                    to[sample] = from[sample] * gain
                }
            }
        }
        let startStatus = status == noErr ? AudioDeviceStart(aggregateID, procID) : status
        guard startStatus == noErr else {
            NSLog("app-volume: 재생 시작 실패 (코드 %d)", startStatus)
            stop()
            return nil
        }
    }

    func stop() {
        if let procID = procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

final class Mixer {
    var gains: [String: Float] = (UserDefaults.standard.dictionary(forKey: "gains") as? [String: Float]) ?? [:]
    var taps: [AudioObjectID: Tap] = [:]
    var processes: [AudioProcess] = []

    var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "muted") ?? [])

    // 탭을 못 만든 프로세스와 실패한 시각. 1초마다 만들고 부수기를 반복하지 않도록 10초 뒤에 다시 시도한다.
    var failedAt: [AudioObjectID: Date] = [:]
    let retryInterval: TimeInterval = 10

    func gain(_ key: String) -> Float { gains[key] ?? 1 }

    // 실제로 곱하는 값. 음소거면 슬라이더 값과 상관없이 0
    func effectiveGain(_ key: String) -> Float { muted.contains(key) ? 0 : gain(key) }

    // 이 앱의 프로세스 중 탭을 못 만들어 볼륨이 적용되지 않은 것이 있는지
    func hasFailure(_ key: String) -> Bool {
        processes.contains { $0.key == key && failedAt[$0.object] != nil }
    }

    func setGain(_ key: String, _ value: Float) {
        gains[key] = value >= 0.98 ? 1 : value
        muted.remove(key)
        persist()
        retryNow(key)
        refresh()
    }

    func setMuted(_ key: String, _ value: Bool) {
        if value { muted.insert(key) } else { muted.remove(key) }
        persist()
        retryNow(key)
        refresh()
    }

    func persist() {
        UserDefaults.standard.set(gains, forKey: "gains")
        UserDefaults.standard.set(Array(muted), forKey: "muted")
    }

    // 사용자가 직접 조절하면 기다리지 않고 바로 다시 시도한다
    func retryNow(_ key: String) {
        for process in processes where process.key == key {
            failedAt[process.object] = nil
        }
    }

    func refresh() {
        processes = listProcesses()
        let alive = Set(processes.map { $0.object })
        for (object, tap) in taps where !alive.contains(object) {
            tap.stop()
            taps[object] = nil
        }
        for object in failedAt.keys where !alive.contains(object) {
            failedAt[object] = nil
        }
        for process in processes {
            let gain = effectiveGain(process.key)
            if gain < 1 {
                if let tap = taps[process.object] {
                    tap.gain = gain
                } else if let failed = failedAt[process.object], Date().timeIntervalSince(failed) < retryInterval {
                    continue
                } else if let tap = Tap(processObject: process.object, gain: gain) {
                    taps[process.object] = tap
                    failedAt[process.object] = nil
                } else {
                    failedAt[process.object] = Date()
                }
            } else {
                if let tap = taps[process.object] {
                    tap.stop()
                    taps[process.object] = nil
                }
                failedAt[process.object] = nil
            }
        }
    }

    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps = [:]
    }
}

let mixer = Mixer()

final class RowView: NSView {
    let key: String
    let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let percent = NSTextField(labelWithString: "")
    let muteButton = NSButton()

    init(key: String, name: String, gain: Float) {
        self.key = key
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 46))

        let title = NSTextField(labelWithString: name)
        title.frame = NSRect(x: 14, y: 26, width: 250, height: 16)
        title.font = .systemFont(ofSize: 12)

        slider.frame = NSRect(x: 14, y: 4, width: 150, height: 20)
        slider.floatValue = mixer.muted.contains(key) ? 0 : gain
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

    func updatePercent() {
        // 탭을 못 만들면 슬라이더 값과 달리 소리가 그대로 나므로 실패를 먼저 보여 준다
        if mixer.hasFailure(key) {
            percent.stringValue = "실패"
            percent.textColor = .systemRed
            percent.toolTip = "볼륨을 적용하지 못했다. 오디오 캡처 권한을 확인한다. 10초마다 다시 시도한다."
            return
        }
        percent.textColor = .labelColor
        percent.toolTip = nil
        percent.stringValue = mixer.muted.contains(key) ? "음소거" : "\(Int(mixer.gain(key) * 100))%"
    }

    // 한 줄을 조작해도 refresh 가 다른 앱의 탭 재시도 결과를 바꿀 수 있어 열린 메뉴의 모든 줄을 갱신한다
    func updateAllRows() {
        for item in enclosingMenuItem?.menu?.items ?? [] {
            (item.view as? RowView)?.updatePercent()
        }
    }

    @objc func muteToggled() {
        mixer.setMuted(key, muteButton.state == .on)
        slider.floatValue = muteButton.state == .on ? 0 : mixer.gain(key)
        updatePercent()
        updateAllRows()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func changed() {
        mixer.setGain(key, slider.floatValue)
        muteButton.state = .off
        updatePercent()
        updateAllRows()
    }
}

// 메뉴에 보일 프로세스: 독에 뜨는 일반 앱은 항상, 시스템 데몬은 소리를 내거나 볼륨을 낮춰 둔 때만
func isListed(_ process: AudioProcess) -> Bool {
    if process.isOutputting || mixer.effectiveGain(process.key) < 1 { return true }
    return NSRunningApplication.runningApplications(withBundleIdentifier: process.key)
        .contains { $0.activationPolicy == .regular }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = mixerIcon()
        menu.delegate = self
        statusItem.menu = menu
        mixer.refresh()
        // 프로세스 목록이 바뀌면 바로 반응한다. 새 프로세스가 소리를 내기 전에 탭을 건다.
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(systemObject, &listAddress, DispatchQueue.main) { _, _ in mixer.refresh() }
        // 리스너와 별도로 1초마다 돈다. 탭을 못 만든 프로세스의 재시도(10초 간격)와
        // 이미 끝났지만 목록에 남아 있던 프로세스가 빠지는 것을 리스너가 놓친 경우를 챙긴다.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in mixer.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.stopAll()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        mixer.refresh()
        menu.removeAllItems()

        var keys: [String] = []
        for process in mixer.processes where isListed(process) {
            if !keys.contains(process.key) { keys.append(process.key) }
        }
        keys.sort { appName($0) < appName($1) }

        if keys.isEmpty {
            let empty = NSMenuItem(title: "지금 소리를 내는 앱이 없다", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for key in keys {
            let item = NSMenuItem()
            item.view = RowView(key: key, name: appName(key), gain: mixer.gain(key))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "로그인할 때 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleLogin() {
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

// 로그인 항목 등록·해제. 앱 폴더 안의 실행 파일로 불러야 동작한다. 실패하면 오류를 돌려준다.
func setLogin(_ enabled: Bool) -> Error? {
    do {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return nil
    } catch {
        print("로그인 항목 변경 실패: \(error)")
        return error
    }
}

// 확인용: 로그인 항목을 바꾸거나 상태를 출력하고 끝낸다
if let index = CommandLine.arguments.firstIndex(of: "--login") {
    let value = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "status"
    if value == "on" { _ = setLogin(true) }
    if value == "off" { _ = setLogin(false) }
    print("로그인 항목 상태: \(SMAppService.mainApp.status.rawValue) (0 미등록, 1 등록됨, 2 승인 필요, 3 찾을 수 없음)")
    exit(0)
}

// 확인용: 목록만 출력하고 끝낸다
if CommandLine.arguments.contains("--list") {
    for process in listProcesses() {
        print("pid \(process.pid)  표시 \(isListed(process))  출력 \(process.isOutputting)  묶음 \(process.key)  이름 \(appName(process.key))")
    }
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
