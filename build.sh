#!/bin/sh
# 실행 파일(mixer)과 앱 폴더(app-volume.app)를 만든다.
# Info.plist 에 오디오 캡처 권한 안내 문구와 메뉴바 전용 설정이 들어 있다.
cd "$(dirname "$0")"
swiftc -O -swift-version 5 mixer.swift -o mixer \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist || exit 1

mkdir -p app-volume.app/Contents/MacOS
cp mixer app-volume.app/Contents/MacOS/mixer
cp Info.plist app-volume.app/Contents/Info.plist
# 임시 서명. 권한이 이 앱에 안정적으로 붙게 한다.
codesign --force --sign - app-volume.app
