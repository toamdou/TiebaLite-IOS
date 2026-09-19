//
//  Regex.swift
//  Kaleidoscope
//
//  Created by Matthew Cheok on 15/11/15.
//  Copyright © 2015 Matthew Cheok. All rights reserved.
//

import Foundation

// TiebaLite patch (Swift 6): 正则缓存改成加锁访问（原实现是裸全局字典，
// 非 Sendable 且并发写不安全）。缓存语义与命中行为不变。
private let expressionsLock = NSLock()
nonisolated(unsafe) private var expressions = [String: NSRegularExpression]()

public extension String {
  func match(regex: String) -> (String, CountableRange<Int>)? {
    let expression: NSRegularExpression
    expressionsLock.lock()
    let cached = expressions[regex]
    expressionsLock.unlock()
    if let cached {
      expression = cached
    } else {
      do {
        expression = try NSRegularExpression(pattern: "^\(regex)", options: [])
        expressionsLock.lock()
        expressions[regex] = expression
        expressionsLock.unlock()
      } catch {
        return nil
      }
    }

    let range = expression.rangeOfFirstMatch(in: self, options: [], range: NSRange(0 ..< self.utf16.count))
    if range.location != NSNotFound {
      return ((self as NSString).substring(with: range), range.location ..< range.location + range.length )
    }
    return nil
  }
}
