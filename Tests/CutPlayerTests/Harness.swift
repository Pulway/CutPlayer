import Foundation

/// 轻量测试 harness（CLT 环境无 XCTest）
public enum Harness {
    public private(set) static var failures = 0
    public private(set) static var passed = 0
    private static var currentSuite = ""

    public static func suite(_ name: String) {
        currentSuite = name
        print("== \(name) ==")
    }

    public static func check(_ cond: Bool, _ name: String, file: String = #fileID, line: Int = #line) {
        if cond {
            passed += 1
            print("  PASS  \(name)")
        } else {
            failures += 1
            print("  FAIL  \(name)  (\(file):\(line))")
        }
    }

    public static func equal<T: Equatable>(_ a: T, _ b: T, _ name: String, file: String = #fileID, line: Int = #line) {
        check(a == b, "\(name) (\(a) == \(b))", file: file, line: line)
    }

    public static func approx(_ a: Double, _ b: Double, accuracy: Double = 0.001, _ name: String, file: String = #fileID, line: Int = #line) {
        check(abs(a - b) <= accuracy, "\(name) (\(a) ≈ \(b) ±\(accuracy))", file: file, line: line)
    }

    public static func nilCheck<T>(_ v: T?, _ name: String, file: String = #fileID, line: Int = #line) {
        check(v == nil, "\(name) 为 nil", file: file, line: line)
    }

    public static func notNil<T>(_ v: T?, _ name: String, file: String = #fileID, line: Int = #line) {
        check(v != nil, "\(name) 非 nil", file: file, line: line)
    }

    public static func summary() -> Bool {
        print("== 结果: \(passed) 通过, \(failures) 失败 ==")
        return failures == 0
    }
}
