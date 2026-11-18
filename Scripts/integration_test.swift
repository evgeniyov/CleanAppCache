#!/usr/bin/env swift
import Foundation

// Smoke checks use only a private fixture tree. A failing prerequisite or
// subprocess must fail the script rather than print an unconditional success.
enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

var failures: [String] = []
func check(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("PASS: \(name)")
    } catch {
        failures.append(name)
        print("FAIL: \(name): \(error)")
    }
}

let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("CleanAppCache-Smoke-\(UUID().uuidString)")
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty && (arguments.count != 2 || arguments[0] != "--probe-path") {
    print("Usage: swift Scripts/integration_test.swift [--probe-path PATH]")
    exit(2)
}

func diskUsage(_ path: URL) throws -> UInt64 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-sk", path.path]
    let output = Pipe()
    process.standardOutput = output
    // A file cannot fill a pipe while stdout is being drained.
    let errorURL = fixture.appendingPathComponent("du-stderr-\(UUID().uuidString)")
    guard fm.createFile(atPath: errorURL.path, contents: nil) else {
        throw CheckFailure.failed("Cannot create subprocess diagnostics")
    }
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer { try? errorHandle.close() }
    process.standardError = errorHandle
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
    defer { watchdog.cancel() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        let diagnostics = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        throw CheckFailure.failed("du exited with \(process.terminationStatus): \(diagnostics)")
    }
    let text = String(decoding: data, as: UTF8.self)
    guard let field = text.split(whereSeparator: { $0.isWhitespace }).first,
          let size = UInt64(field) else {
        throw CheckFailure.failed("du returned no numeric size")
    }
    return size
}

check("Create isolated fixtures") {
    try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
    let payload = fixture.appendingPathComponent("payload")
    try fm.createDirectory(at: payload, withIntermediateDirectories: false)
    try Data(repeating: 0x42, count: 8192).write(to: payload.appendingPathComponent("sample.bin"))
}
check("Volume capacity") {
    let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
    guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity,
          total > 0, free >= 0, free <= total else {
        throw CheckFailure.failed("Missing or invalid volume capacity")
    }
}
check("Applications directory listing") {
    _ = try fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)
}
check("File metadata") {
    let file = fixture.appendingPathComponent("payload/sample.bin")
    let values = try file.resourceValues(forKeys: [.fileSizeKey])
    guard values.fileSize == 8192 else { throw CheckFailure.failed("Incorrect file size") }
}
check("Directory sizing subprocess") {
    let path = arguments.isEmpty ? fixture.appendingPathComponent("payload") : URL(fileURLWithPath: arguments[1])
    _ = try diskUsage(path)
}
check("Remove only this script's temporary fixtures") {
    if fm.fileExists(atPath: fixture.path) { try fm.removeItem(at: fixture) }
}
if failures.isEmpty {
    print("Integration smoke checks passed. No existing user files were changed.")
    exit(0)
}
print("Integration smoke checks failed: \(failures.joined(separator: ", "))")
exit(1)
