import AppKit

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
