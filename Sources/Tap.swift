import CoreAudio
import Foundation

// IO 블록이 읽는 볼륨 값. 메인 스레드에서 쓰고 IO 스레드에서 읽는다. 4바이트 정렬 값이라 읽다 깨지지 않는다.
// 블록이 Tap 이 아니라 이 상자만 잡아서, Tap 이 해제되는 중(deinit)에 블록이 한 번 더 돌아도 안전하다.
final class GainBox {
    var value: Float
    init(_ value: Float) { self.value = value }
}

// 프로세스 하나의 소리를 탭으로 잡아 원래 출력은 끄고, 볼륨을 곱해 기본 출력 장치로 다시 낸다.
// 실패하면 nil 을 돌려주고, 그때까지 만든 것은 deinit 의 stop() 이 정리한다.
final class Tap {
    let box: GainBox
    var gain: Float {
        get { box.value }
        set { box.value = newValue }
    }
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?

    init?(processObject: AudioObjectID, gain: Float) {
        box = GainBox(gain)

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = UUID()
        description.muteBehavior = .muted
        // 다른 프로세스에 탭이 보이지 않게 한다
        description.isPrivate = true
        // 메뉴바 앱이라 print 는 보이지 않는다. 실패 원인은 NSLog 로 남겨 콘솔 앱에서 찾게 한다.
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            NSLog("app-volume: 탭 만들기 실패 (코드 %d)", tapStatus)
            tapID = AudioObjectID(kAudioObjectUnknown)
            return nil
        }

        // 효과음용 장치(DefaultSystemOutputDevice)가 아니라 소리 설정의 기본 출력 장치로 낸다
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        var uidRef: Unmanaged<CFString>?
        guard audioProperty(systemObject, kAudioHardwarePropertyDefaultOutputDevice, &outputDevice),
              audioProperty(outputDevice, kAudioDevicePropertyDeviceUID, &uidRef),
              let uid = uidRef?.takeRetainedValue() as String? else {
            NSLog("app-volume: 출력 장치 얻기 실패")
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
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            return nil
        }

        // 탭의 왼쪽·오른쪽을 장치가 정한 스테레오 쌍으로 낸다. 못 읽으면 1·2번 채널
        var stereo: (UInt32, UInt32) = (1, 2)
        var stereoAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var stereoSize = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        if AudioObjectGetPropertyData(outputDevice, &stereoAddress, 0, nil, &stereoSize, &stereo) != noErr || stereo.0 < 1 || stereo.1 < 1 {
            stereo = (1, 2)
        }
        let leftChannel = Int(stereo.0) - 1
        let rightChannel = Int(stereo.1) - 1

        let box = self.box
        let queue = DispatchQueue(label: "app-volume.io", qos: .userInteractive)
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, outData, _ in
            mixTap(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                   into: UnsafeMutableAudioBufferListPointer(outData),
                   left: leftChannel, right: rightChannel,
                   gain: box.value)
        }
        guard procStatus == noErr else {
            NSLog("app-volume: 재생 함수 등록 실패 (코드 %d)", procStatus)
            procID = nil
            return nil
        }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            NSLog("app-volume: 재생 시작 실패 (코드 %d)", startStatus)
            return nil
        }
    }

    // 정리 순서: 재생을 멈추고 재생 함수를 지운 뒤 집합 장치와 탭을 지운다. 여러 번 불러도 된다.
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

    // stop() 을 빠뜨리고 놓아도 Core Audio 객체가 남지 않게 한다
    deinit { stop() }
}

// 버퍼 목록 안의 채널 하나: 첫 샘플 위치, 다음 프레임까지의 간격(그 버퍼의 채널 수), 프레임 수
struct Channel {
    let samples: UnsafeMutablePointer<Float>
    let stride: Int
    let frames: Int
}

// 버퍼 목록에서 number 번째 채널을 찾는다. 인터리브 한 버퍼든 채널마다 한 버퍼든 같은 번호로 센다.
func channel(_ list: UnsafeMutableAudioBufferListPointer, _ number: Int) -> Channel? {
    var first = 0
    for buffer in list {
        let count = Int(buffer.mNumberChannels)
        if number < first + count {
            guard let data = buffer.mData else { return nil }
            return Channel(samples: data.assumingMemoryBound(to: Float.self) + (number - first),
                           stride: count,
                           frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count))
        }
        first += count
    }
    return nil
}

func sample(_ channel: Channel?, _ frame: Int) -> Float {
    guard let channel = channel, frame < channel.frames else { return 0 }
    return channel.samples[frame * channel.stride]
}

// 탭(입력 첫 두 채널, 스테레오)을 출력 장치의 left·right 번 채널(0부터)에 볼륨을 곱해 옮긴다.
// 나머지 출력 채널은 0, 모노 장치면 좌우를 섞는다. IO 스레드에서 돌므로 메모리를 잡지 않는다.
func mixTap(_ input: UnsafeMutableAudioBufferListPointer, into output: UnsafeMutableAudioBufferListPointer,
            left leftChannel: Int, right rightChannel: Int, gain: Float) {
    let left = channel(input, 0)
    let right = channel(input, 1)
    var total = 0
    for buffer in output { total += Int(buffer.mNumberChannels) }
    // 장치가 알려 준 채널 번호가 실제 채널 수를 넘으면 1·2번으로 낸다
    let fits = leftChannel < total && rightChannel < total
    let leftOut = fits ? leftChannel : 0
    let rightOut = fits ? rightChannel : 1
    for number in 0..<total {
        guard let out = channel(output, number) else { continue }
        for frame in 0..<out.frames {
            let value: Float
            if total == 1 || (number == leftOut && leftOut == rightOut) {
                // 모노 장치이거나 장치 설정이 좌우를 같은 채널로 정했으면 좌우를 섞는다
                value = (sample(left, frame) + sample(right, frame)) / 2
            } else if number == leftOut {
                value = sample(left, frame)
            } else if number == rightOut {
                value = sample(right, frame)
            } else {
                value = 0
            }
            out.samples[frame * out.stride] = value * gain
        }
    }
}
