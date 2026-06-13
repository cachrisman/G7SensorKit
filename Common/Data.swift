//
//  NSData.swift
//  xDripG5
//
//  Created by Nathan Racklyeft on 3/5/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation


extension Data {
    private func toDefaultEndian<T: FixedWidthInteger>(_: T.Type) -> T {
        // C-209-12 (review 1.5): length-checked. The previous `bufferPointer.pointee` read
        // `MemoryLayout<T>.size` bytes unconditionally, so a slice shorter than T (e.g. a 3-byte
        // slice read as UInt32) read past the buffer end — a latent out-of-bounds read. Copy the
        // available bytes into a zero-initialized stack value: a short slice can never over-read,
        // and for a correctly sized slice the in-memory result is byte-identical to the old read
        // (so `to`/`toBigEndian` are unchanged on valid input).
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { dest in
            self.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                let n = Swift.min(dest.count, src.count)
                if n > 0 {
                    dest.copyMemory(from: UnsafeRawBufferPointer(start: base, count: n))
                }
            }
        }
        return value
    }

    func to<T: FixedWidthInteger>(_ type: T.Type) -> T {
        return T(littleEndian: toDefaultEndian(type))
    }

    func toInt<T: FixedWidthInteger>() -> T {
        return to(T.self)
    }

    func toBigEndian<T: FixedWidthInteger>(_ type: T.Type) -> T {
        return T(bigEndian: toDefaultEndian(type))
    }

    mutating func append<T: FixedWidthInteger>(_ newElement: T) {
        withUnsafePointer(to: newElement.littleEndian) { (ptr: UnsafePointer<T>) in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ newElement: T) {
        withUnsafePointer(to: newElement.bigEndian) { (ptr: UnsafePointer<T>) in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    init<T: FixedWidthInteger>(_ value: T) {
        self = withUnsafePointer(to: value.littleEndian) { (ptr: UnsafePointer<T>) -> Data in
            return Data(buffer: UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    init<T: FixedWidthInteger>(bigEndian value: T) {
        self = withUnsafePointer(to: value.bigEndian) { (ptr: UnsafePointer<T>) -> Data in
            return Data(buffer: UnsafeBufferPointer(start: ptr, count: 1))
        }
    }
}


// String conversion methods, adapted from https://stackoverflow.com/questions/40276322/hex-binary-string-conversion-in-swift/40278391#40278391
extension Data {
    init?(hexadecimalString: String) {
        self.init(capacity: hexadecimalString.utf16.count / 2)

        // Convert 0 ... 9, a ... f, A ...F to their decimal value,
        // return nil for all other input characters
        func decodeNibble(u: UInt16) -> UInt8? {
            switch u {
            case 0x30 ... 0x39:  // '0'-'9'
                return UInt8(u - 0x30)
            case 0x41 ... 0x46:  // 'A'-'F'
                return UInt8(u - 0x41 + 10)  // 10 since 'A' is 10, not 0
            case 0x61 ... 0x66:  // 'a'-'f'
                return UInt8(u - 0x61 + 10)  // 10 since 'a' is 10, not 0
            default:
                return nil
            }
        }

        var even = true
        var byte: UInt8 = 0
        for c in hexadecimalString.utf16 {
            guard let val = decodeNibble(u: c) else { return nil }
            if even {
                byte = val << 4
            } else {
                byte += val
                self.append(byte)
            }
            even = !even
        }
        guard even else { return nil }
    }

    var hexadecimalString: String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
