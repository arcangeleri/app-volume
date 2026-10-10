#!/bin/sh
# 오디오 캡처 권한 문구가 든 Info.plist 를 실행 파일에 넣어 빌드한다.
cd "$(dirname "$0")"
swiftc -O -swift-version 5 mixer.swift -o mixer \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
