#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ApplicationServices

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: benchmark-utterance.swift <phrase>\n".utf8))
    exit(64)
}

let phrase = CommandLine.arguments.dropFirst().joined(separator: " ")
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is required for synthetic hotkey events\n".utf8))
    exit(77)
}
guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false) else {
    FileHandle.standardError.write(Data("could not create keyboard events\n".utf8))
    exit(1)
}

down.flags = .maskAlternate
up.flags = .maskAlternate
down.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.35)

let speech = Process()
speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
speech.arguments = [phrase]
try speech.run()
speech.waitUntilExit()
Thread.sleep(forTimeInterval: 0.35)
up.post(tap: .cghidEventTap)

guard speech.terminationStatus == 0 else { exit(speech.terminationStatus) }
