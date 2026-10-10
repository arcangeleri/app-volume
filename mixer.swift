import AppKit
import CoreAudio

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

// 앱 이름으로 묶는 키. 크롬 같은 도우미 프로세스는 본체 번들 이름으로 합친다.
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
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            print("탭 만들기 실패")
            return nil
        }

        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        var uidRef: Unmanaged<CFString>?
        guard audioProperty(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, &outputDevice),
              audioProperty(outputDevice, kAudioDevicePropertyDeviceUID, &uidRef),
              let uid = uidRef?.takeRetainedValue() as String? else {
            print("출력 장치 얻기 실패")
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
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            print("집합 장치 만들기 실패")
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
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            print("재생 시작 실패")
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

    func gain(_ key: String) -> Float { gains[key] ?? 1 }

    // 실제로 곱하는 값. 음소거면 슬라이더 값과 상관없이 0
    func effectiveGain(_ key: String) -> Float { muted.contains(key) ? 0 : gain(key) }

    func setGain(_ key: String, _ value: Float) {
        gains[key] = value >= 0.98 ? 1 : value
        muted.remove(key)
        UserDefaults.standard.set(gains, forKey: "gains")
        UserDefaults.standard.set(Array(muted), forKey: "muted")
        refresh()
    }

    func setMuted(_ key: String, _ value: Bool) {
        if value { muted.insert(key) } else { muted.remove(key) }
        UserDefaults.standard.set(Array(muted), forKey: "muted")
        refresh()
    }

    func refresh() {
        processes = listProcesses()
        let alive = Set(processes.map { $0.object })
        for (object, tap) in taps where !alive.contains(object) {
            tap.stop()
            taps[object] = nil
        }
        for process in processes {
            let gain = effectiveGain(process.key)
            if gain < 1 {
                if let tap = taps[process.object] {
                    tap.gain = gain
                } else {
                    taps[process.object] = Tap(processObject: process.object, gain: gain)
                }
            } else if let tap = taps[process.object] {
                tap.stop()
                taps[process.object] = nil
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
        percent.stringValue = mixer.muted.contains(key) ? "음소거" : "\(Int(mixer.gain(key) * 100))%"
    }

    @objc func muteToggled() {
        mixer.setMuted(key, muteButton.state == .on)
        slider.floatValue = muteButton.state == .on ? 0 : mixer.gain(key)
        updatePercent()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func changed() {
        mixer.setGain(key, slider.floatValue)
        muteButton.state = .off
        updatePercent()
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
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
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
