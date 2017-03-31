//
//  KVO.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/09/11.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import Foundation
import SwiftTask

// NSNull-to-nil converter for KVO which returns NSNull when nil is set
// https://github.com/ReactKit/ReactKit/pull/18
internal func _nullToNil(_ value: Any?) -> Any? {
    return (value is NSNull) ? nil : value
}

public extension NSObject {
    /// creates new KVO Stream (new value only)
    public func stream(_ keyPath: String) -> Stream<Any?> {
        let stream = self.detailedStream(keyPath)
            |> map { value, _, _ -> Any? in value }
        
        return stream.name("KVO.stream(\(_summary(self)), \"\(keyPath)\")")
    }
    
    /// creates new KVO Stream (initial + new value)
    public func startingStream(_ keyPath: String) -> Stream<Any?> {
        let initial: Any? = self.value(forKeyPath: keyPath)
        
        let stream = self.stream(keyPath)
            |> startWith(_nullToNil(initial))
        
        return stream.name("KVO.startingStream(\(_summary(self)), \"\(keyPath)\")")
    }
    
    ///
    /// creates new KVO Stream (new value, keyValueChange, indexSet),
    /// useful for array model with combination of `mutableArrayValueForKey()`.
    ///
    /// e.g.
    /// let itemsStream = model.detailedStream("items")
    /// itemsStream ~> { changedItems, change, indexSet in ... /* do something with changed items */}
    /// let itemsProxy = model.mutableArrayValueForKey("items")
    /// itemsProxy.insertObject(newItem, atIndex: 0) // itemsStream will send **both** `newItem` and `index`
    ///
    public func detailedStream(_ keyPath: String) -> Stream<(Any?, NSKeyValueChange, IndexSet?)> {
        return Stream { [weak self] progress, fulfill, reject, configure in
            if let self_ = self {
                let observer = _KVOProxy(target: self_, keyPath: keyPath) { value, change, indexSet in
                    progress((_nullToNil(value), change, indexSet))
                }
                
                configure.pause = { observer.stop() }
                configure.resume = { observer.start() }
                configure.cancel = { observer.stop() }
                
                configure.resume?()
            }
        }.name("KVO.detailedStream(\(_summary(self)), \"\(keyPath)\")") |> takeUntil(self.deinitStream)
    }
}

/// KVO helper
public struct KVO {
    /// creates new KVO Stream (new value only)
    public static func stream(_ object: NSObject, _ keyPath: String) -> Stream<Any?> {
        return object.stream(keyPath)
    }
    
    /// creates new KVO Stream (initial + new value)
    public static func startingStream(_ object: NSObject, _ keyPath: String) -> Stream<Any?> {
        return object.startingStream(keyPath)
    }

    /// creates new KVO Stream (new value, keyValueChange, indexSet)
    public static func detailedStream(_ object: NSObject, _ keyPath: String) -> Stream<(Any?, NSKeyValueChange, IndexSet?)> {
        return object.detailedStream(keyPath)
    }
}

private var ReactKitKVOContext = 0

// NOTE: KVO won't work if generics is used in this class
internal class _KVOProxy: NSObject {
    internal typealias _Handler = (_ value: Any?, _ change: NSKeyValueChange, _ indexSet: IndexSet?) -> Void
    
    internal let _target: NSObject
    internal let _keyPath: String
    internal let _handler: _Handler
    
    internal var _isObserving: Bool = false
    
    internal init(target: NSObject, keyPath: String, handler: @escaping _Handler) {
        self._target = target
        self._keyPath = keyPath
        self._handler = handler
        
        super.init()
        
        self.start()
    }
    
    deinit {
        self.stop()
    }
    
    internal func start() {
        if _isObserving { return }
        _isObserving = true
        self._target.addObserver(self, forKeyPath: self._keyPath, options: .new, context: &ReactKitKVOContext)
    }
    
    internal func stop() {
        if !_isObserving { return }
        _isObserving = false
        self._target.removeObserver(self, forKeyPath: self._keyPath)
    }
    
    internal override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context != &ReactKitKVOContext {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        } else {
            let newValue: Any? = change?[NSKeyValueChangeKey.newKey]
            let keyValueChange: NSKeyValueChange = NSKeyValueChange(rawValue: (change?[NSKeyValueChangeKey.kindKey] as! NSNumber).uintValue)!
            let indexSet: IndexSet? = change?[NSKeyValueChangeKey.indexesKey] as? IndexSet
            
            self._handler(newValue, keyValueChange, indexSet)
        }
    }
}

extension NSKeyValueChange: CustomStringConvertible {
    public var description: String {
        switch self {
            case .setting:      return "Setting"
            case .insertion:    return "Insertion"
            case .removal:      return "Removal"
            case .replacement:  return "Replacement"
        }
    }
}

//--------------------------------------------------
// MARK: - Custom Operators
// + - * / % = < > ! & | ^ ~ .
//--------------------------------------------------

precedencegroup KVOReactingPrecedence {
    associativity: right
}

infix operator <~ : KVOReactingPrecedence

/// Key-Value Binding
/// e.g. `(obj2, "value") <~ stream`
@discardableResult public func <~ <T: Any>(tuple: (object: NSObject, keyPath: String), stream: Stream<T?>) -> Canceller? {
    return _reactLeft(tuple, stream)
}

@discardableResult public func <~ (tuple: (object: NSObject, keyPath: String), stream: Stream<String?>) -> Canceller? {
    return _reactLeft(tuple, stream)
}

@discardableResult public func <~ (tuple: (object: NSObject, keyPath: String), stream: Stream<Int?>) -> Canceller? {
    return _reactLeft(tuple, stream)
}

@discardableResult public func <~ (tuple: (object: NSObject, keyPath: String), stream: Stream<Float?>) -> Canceller? {
    return _reactLeft(tuple, stream)
}

@discardableResult public func <~ (tuple: (object: NSObject, keyPath: String), stream: Stream<Double?>) -> Canceller? {
    return _reactLeft(tuple, stream)
}

private func _reactLeft <T>(_ tuple: (object: NSObject, keyPath: String), _ stream: Stream<T?>) -> Canceller? {
    weak var object = tuple.object
    let keyPath = tuple.keyPath
    var canceller: Canceller? = nil
    
    stream.react(&canceller) { value in
        if let object = object {
            object.setValue(value, forKeyPath:keyPath)  // NOTE: don't use `tuple` inside closure, or object will be captured
        }
    }
    
    return canceller
}
