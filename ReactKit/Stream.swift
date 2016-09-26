//
//  ReactKit.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/09/11.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import SwiftTask

public class Stream<T>: Task<T, Void, Error> {
    public typealias Producer = () -> Stream<T>
    
    public override var description: String {
        return "<\(self.name); state=\(self.state.rawValue)>"
    }
    
    ///
    /// Creates a new stream (event-delivery-pipeline over time).
    /// Synonym of "signal", "observable", etc.
    ///
    /// - parameter initClosure: Closure to define returning stream's behavior. Inside this closure, `configure.pause`/`resume`/`cancel` should capture inner logic (player) object. See also comment in `SwiftTask.Task.init()`.
    ///
    /// - returns: New Stream.
    /// 
    public init(initClosure: @escaping Task<T, Void, Error>.InitClosure) {
        //
        // NOTE: 
        // - set `weakified = true` to avoid "(inner) player -> stream" retaining
        // - set `paused = true` for lazy evaluation (similar to "cold stream")
        //
        super.init(weakified: true, paused: true, initClosure: initClosure)
        
        self.name = "DefaultStream"
    }
    
    deinit {
        let cancelError = _RKError(.cancelledByDeinit, "Stream=\(self.name) is cancelled via deinit.")
        
        self.cancel(error: cancelError)
    }
    
    /// progress-chaining with auto-resume
    @discardableResult public func react(_ reactClosure: @escaping (T) -> Void) -> Self {
        var dummyCanceller: Canceller? = nil
        return self.react(&dummyCanceller, reactClosure: reactClosure)
    }
    
    @discardableResult public func react<C: Canceller>(_ canceller: inout C?, reactClosure: @escaping (T) -> Void) -> Self {
        let _ = super.progress(&canceller) { _, value in reactClosure(value) }
        self.resume()
        return self
    }
    
    /// Easy strong referencing by owner e.g. UIViewController holding its UI component's stream
    /// without explicitly defining stream as property.
    public func ownedBy(_ owner: NSObject) -> Stream<T> {
        var owningStreams = owner._owningStreams
        owningStreams.append(self)
        owner._owningStreams = owningStreams
        
        return self
    }
}

//--------------------------------------------------
// MARK: - Init Helper
/// (TODO: move to new file, but doesn't work in Swift 1.1. ERROR = ld: symbol(s) not found for architecture x86_64)
//--------------------------------------------------

public extension Stream {
    /// creates once (progress once & fulfill) stream
    /// NOTE: this method can't move to other file due to Swift 1.1
    public class func once(_ value: T) -> Stream<T> {
        return Stream { progress, fulfill, reject, configure in
            progress(value)
            fulfill()
        }.name("Stream.once(\(value))")
    }
    
    /// creates never (no progress & fulfill & reject) stream
    public class func never() -> Stream<T> {
        return Stream { progress, fulfill, reject, configure in
            // do nothing
        }.name("Stream.never")
    }
    
    /// creates empty (fulfilled without any progress) stream
    public class func fulfilled() -> Stream<T> {
        return Stream { progress, fulfill, reject, configure in
            fulfill()
        }.name("Stream.fulfilled")
    }
    
    /// creates error (rejected) stream
    public class func rejected(_ error: Error) -> Stream<T> {
        return Stream { progress, fulfill, reject, configure in
            reject(error)
        }.name("Stream.rejected(\(error))")
    }
    
    ///
    /// creates **synchronous** stream from SequenceType (e.g. Array) and fulfills at last,
    /// a.k.a `Rx.fromArray`
    ///
    /// - e.g. Stream.sequence([1, 2, 3])
    ///
    public class func sequence<S: Sequence>(_ values: S) -> Stream<T> where S.Iterator.Element == T {
        return Stream { progress, fulfill, reject, configure in
            for value in values {
                progress(value)
                if configure.isFinished { break }
            }
            fulfill()
        }.name("Stream.sequence")
    }
    
    ///
    /// creates **synchronous** stream which can send infinite number of values
    /// by using `initialValue` and `nextClosure`,
    /// a.k.a `Rx.generate`
    ///
    /// :Example:
    /// - `Stream.infiniteSequence(0) { $0 + 1 }` will emit 0, 1, 2, ...
    ///
    /// NOTE: To prevent infinite loop, use `take(maxCount)` to limit the number of value generation.
    ///
    public class func infiniteSequence(_ initialValue: T, nextClosure: @escaping (T) -> T) -> Stream<T> {
        let iterator = _InfiniteIterator<T>(initialValue: initialValue, nextClosure: nextClosure)
        return Stream<T>.sequence(AnySequence({iterator})).name("Stream.infiniteSequence")
    }
}

//--------------------------------------------------
// MARK: - Single Stream Operations
//--------------------------------------------------

/// useful for injecting side-effects
/// a.k.a Rx.do, tap
public func peek<T>(_ peekClosure: @escaping (T) -> Void) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            upstream.react(&canceller) { value in
                peekClosure(value)
                progress(value)
            }
        }.name("\(upstream.name) |> peek")
    }
}

/// Stops pause/resume/cancel propagation to upstream, and only pass-through `progressValue`s to downstream.
/// Useful for oneway-pipelining to consecutive downstream.
public func branch<T>(_ upstream: Stream<T>) -> Stream<T> {
    return Stream<T> { progress, fulfill, reject, configure in
        var canceller: Canceller? = nil
        _bindToUpstream(upstream, fulfill, reject, nil, canceller)
        
        // configure manually to not propagate pause/resume/cancel to upstream
        configure.cancel = {
            canceller?.cancel()
        }
        
        // NOTE: use `upstream.progress()`, not `.react()`
        let _ = upstream.progress(&canceller) { _, value in
            progress(value)
        }
    }.name("\(upstream.name) |> branch")
}

/// creates your own customizable & method-chainable stream without writing `return Stream<U> { ... }`
public func customize<T, U>(_ customizeClosure: @escaping (_ upstream: Stream<T>, _ progress: Stream<U>.ProgressHandler, _ fulfill: Stream<U>.FulfillHandler, _ reject: Stream<U>.RejectHandler) -> Void) -> (_ upstream: Stream<T>) -> Stream<U> {
    return { (upstream: Stream<T>) in
        return Stream<U> { progress, fulfill, reject, configure in
            _bindToUpstream(upstream, nil, nil, configure, nil)
            customizeClosure(upstream, progress, fulfill, reject)
        }.name("\(upstream.name) |> customize")
    }
}

// MARK: transforming

/// map using newValue only
public func map<T, U>(_ transform: @escaping (T) -> U) -> (_ upstream: Stream<T>) -> Stream<U> {
    return { (upstream: Stream<T>) in
        return Stream<U> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            upstream.react(&canceller) { value in
                progress(transform(value))
            }
        }.name("\(upstream.name) |> map")
    }
}

/// map using (oldValue, newValue)
public func map2<T, U>(_ transform2: @escaping (_ oldValue: T?, _ newValue: T) -> U) -> (_ upstream: Stream<T>) -> Stream<U> {
    return { (upstream: Stream<T>) in
        var oldValue: T?
        
        let stream = upstream |> map { (newValue: T) -> U in
            let mappedValue = transform2(oldValue, newValue)
            oldValue = newValue
            return mappedValue
        }
        
        return stream.name("\(upstream.name) |> map2")
    }
}

// NOTE: Avoid using curried function. See comments in `startWith()`.
/// map using (accumulatedValue, newValue)
/// a.k.a `Rx.scan()`
public func mapAccumulate<T, U>(_ initialValue: U, _ accumulateClosure: @escaping (_ accumulatedValue: U, _ newValue: T) -> U) -> (_ upstream: Stream<T>) -> Stream<U> {
    return { (upstream: Stream<T>) in
        return Stream<U> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            var accumulatedValue: U = initialValue
            
            upstream.react(&canceller) { value in
                accumulatedValue = accumulateClosure(accumulatedValue, value)
                progress(accumulatedValue)
            }
        }.name("\(upstream.name) |> mapAccumulate")
    }
}

/// map to stream + flatten
public func flatMap<T, U>(_ style: FlattenStyle = .merge, transform: @escaping (T) -> Stream<U>) -> (_ upstream: Stream<T>) -> Stream<U> {
    return { (upstream: Stream<T>) in
        let stream = upstream |> map(transform) |> flatten(style)
        return stream.name("\(upstream.name) |> flatMap(.\(style))")
    }
}

public func buffer<T>(_ capacity: Int = Int.max) -> (_ upstream: Stream<T>) -> Stream<[T]> {
    precondition(capacity >= 0)
 
    return { (upstream: Stream<T>) in
        return Stream<[T]> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, nil, reject, configure, canceller)
            
            var buffer: [T] = []
            
            upstream.react(&canceller) { value in
                buffer += [value]
                if buffer.count >= capacity {
                    progress(buffer)
                    buffer = []
                }
            }.success { _ -> Void in
                if buffer.count > 0 {
                    progress(buffer)
                }
                fulfill()
            }
        }.name("\(upstream.name) |> buffer")
    }
}

public func bufferBy<T, U>(_ triggerStream: Stream<U>) -> (_ upstream: Stream<T>) -> Stream<[T]> {
    return { (upstream: Stream<T>) in
        return Stream<[T]> { [weak triggerStream] progress, fulfill, reject, configure in
            var upstreamCanceller: Canceller? = nil
            var triggerCanceller: Canceller? = nil
            let combinedCanceller = Canceller {
                upstreamCanceller?.cancel()
                triggerCanceller?.cancel()
            }
            _bindToUpstream(upstream, nil, reject, configure, combinedCanceller)
            
            var buffer: [T] = []
            
            upstream.react(&upstreamCanceller) { value in
                buffer += [value]
            }.success { _ -> Void in
                progress(buffer)
                fulfill()
            }
            
            triggerStream?.react(&triggerCanceller) { [weak upstream] _ in
                if upstream != nil {
                    progress(buffer)
                    buffer = []
                }
            }.then { [weak upstream] _ -> Void in
                if upstream != nil {
                    progress(buffer)
                    buffer = []
                }
            }
        }.name("\(upstream.name) |> bufferBy")
    }
}

public func groupBy<T, Key: Hashable>(_ groupingClosure: @escaping (T) -> Key) -> (_ upstream: Stream<T>) -> Stream<(Key, Stream<T>)> {
    return { (upstream: Stream<T>) in
        return Stream<(Key, Stream<T>)> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            var buffer: [Key : (stream: Stream<T>, progressHandler: Stream<T>.ProgressHandler)] = [:]
            
            upstream.react(&canceller) { value in
                let key = groupingClosure(value)
                
                if buffer[key] == nil {
                    var progressHandler: Stream<T>.ProgressHandler?
                    let innerStream = Stream<T> { p, _, _, _ in
                        progressHandler = p;    // steal progressHandler
                        return
                    }
                    innerStream.resume()    // resume to steal `progressHandler` immediately
                    
                    buffer[key] = (innerStream, progressHandler!) // set innerStream
                    
                    progress((key as Key, buffer[key]!.stream as Stream<T>))
                }
                
                buffer[key]!.progressHandler(value) // push value to innerStream
            }
        }.name("\(upstream.name) |> groupBy")
    }
}

// MARK: filtering

/// filter using newValue only
public func filter<T>(_ filterClosure: @escaping (T) -> Bool) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            upstream.react(&canceller) { value in
                if filterClosure(value) {
                    progress(value)
                }
            }
        }.name("\(upstream.name) |> filter")
    }
}

/// filter using (oldValue, newValue)
public func filter2<T>(_ filterClosure2: @escaping (_ oldValue: T?, _ newValue: T) -> Bool) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        var oldValue: T?
        
        let stream = upstream |> filter { (newValue: T) -> Bool in
            let flag = filterClosure2(oldValue, newValue)
            oldValue = newValue
            return flag
        }
        return stream.name("\(upstream.name) |> filter2")
    }
}

public func take<T>(_ maxCount: Int) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, nil, reject, configure, canceller)
            
            var count = 0
            
            upstream.react(&canceller) { value in
                count += 1
                
                if count < maxCount {
                    progress(value)
                } else if count == maxCount {
                    progress(value)
                    fulfill()   // successfully reached maxCount
                }
            }
        }.name("\(upstream.name) |> take(\(maxCount))")
    }
}

public func takeUntil<T, U>(_ triggerStream: Stream<U>) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { [weak triggerStream] progress, fulfill, reject, configure in
            if let triggerStream = triggerStream {
                var upstreamCanceller: Canceller? = nil
                var triggerCanceller: Canceller? = nil
                let combinedCanceller = Canceller {
                    upstreamCanceller?.cancel()
                    triggerCanceller?.cancel()
                }
                _bindToUpstream(upstream, fulfill, reject, configure, combinedCanceller)
                
                upstream.react(&upstreamCanceller) { value in
                    progress(value)
                }

                let cancelError = _RKError(.cancelledByTriggerStream, "Stream=\(upstream.name) is cancelled by takeUntil(\(triggerStream.name)).")
                
                triggerStream.react(&triggerCanceller) { [weak upstream] _ in
                    if let upstream_ = upstream {
                        upstream_.cancel(error: cancelError)
                    }
                }.then { [weak upstream] _ -> Void in
                    if let upstream_ = upstream {
                        upstream_.cancel(error: cancelError)
                    }
                }
            } else {
                let cancelError = _RKError(.cancelledByTriggerStream, "Stream=\(upstream.name) is cancelled by takeUntil() with `triggerStream` already been deinited.")
                upstream.cancel(error: cancelError)
            }
        }.name("\(upstream.name) |> takeUntil")
    }
}

public func skip<T>(_ skipCount: Int) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            var count = 0
            
            upstream.react(&canceller) { value in
                count += 1
                if count <= skipCount { return }
                
                progress(value)
            }
        }.name("\(upstream.name) |> skip(\(skipCount))")
    }
}

public func skipUntil<T, U>(_ triggerStream: Stream<U>) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { [weak triggerStream] progress, fulfill, reject, configure in
            var upstreamCanceller: Canceller? = nil
            var triggerCanceller: Canceller? = nil
            let combinedCanceller = Canceller {
                upstreamCanceller?.cancel()
                triggerCanceller?.cancel()
            }
            _bindToUpstream(upstream, fulfill, reject, configure, combinedCanceller)
            
            var shouldSkip = true
            
            upstream.react(&upstreamCanceller) { value in
                if !shouldSkip {
                    progress(value)
                }
            }
            
            if let triggerStream = triggerStream {
                triggerStream.react(&triggerCanceller) { _ in
                    shouldSkip = false
                }.then { _ -> Void in
                    shouldSkip = false
                }
            } else {
                shouldSkip = false
            }
        }.name("\(upstream.name) |> skipUntil")
    }
}

public func sample<T, U>(_ triggerStream: Stream<U>) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { [weak triggerStream] progress, fulfill, reject, configure in
            var upstreamCanceller: Canceller? = nil
            var triggerCanceller: Canceller? = nil
            let combinedCanceller = Canceller {
                upstreamCanceller?.cancel()
                triggerCanceller?.cancel()
            }
            _bindToUpstream(upstream, fulfill, reject, configure, combinedCanceller)
            
            var lastValue: T?
            
            upstream.react(&upstreamCanceller) { value in
                lastValue = value
            }
            
            if let triggerStream = triggerStream {
                triggerStream.react(&triggerCanceller) { _ in
                    if let lastValue = lastValue {
                        progress(lastValue)
                    }
                }
            }
        }
    }
}

public func distinct<H: Hashable>(_ upstream: Stream<H>) -> Stream<H> {
    return Stream<H> { progress, fulfill, reject, configure in
        var canceller: Canceller? = nil
        _bindToUpstream(upstream, fulfill, reject, configure, canceller)
        
        var usedValueHashes = Set<H>()
        
        upstream.react(&canceller) { value in
            if !usedValueHashes.contains(value) {
                usedValueHashes.insert(value)
                progress(value)
            }
        }
    }
}

public func distinctUntilChanged<E: Equatable>(_ upstream: Stream<E>) -> Stream<E> {
    let stream = upstream |> filter2 { $0 != $1 }
    return stream.name("\(upstream.name) |> distinctUntilChanged")
}

// MARK: combining

public func merge<T>(_ stream: Stream<T>) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return upstream |> merge([stream])
    }
}

public func merge<T>(_ streams: [Stream<T>]) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        let stream = (streams + [upstream]) |> mergeInner
        return stream.name("\(upstream.name) |> merge")
    }
}

public func concat<T>(_ nextStream: Stream<T>) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return upstream |> concat([nextStream])
    }
}

public func concat<T>(_ nextStreams: [Stream<T>]) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        let stream = ([upstream] + nextStreams) |> concatInner
        return stream.name("\(upstream.name) |> concat")
    }
}

//
// NOTE:
// Avoid using curried function since `initialValue` seems to get deallocated at uncertain timing
// (especially for T as value-type e.g. String, but also occurs a little in reference-type e.g. NSString).
// Make sure to let `initialValue` be captured by closure explicitly.
//
/// `concat()` initialValue first
public func startWith<T>(_ initialValue: T) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        precondition(upstream.state == .Paused)
        
        let stream = [Stream.once(initialValue), upstream] |> concatInner
        return stream.name("\(upstream.name) |> startWith")
    }
}
//public func startWith<T>(initialValue: T)(upstream: Stream<T>) -> Stream<T>
//{
//    let stream = [Stream.once(initialValue), upstream] |> concatInner
//    return stream.name("\(upstream.name) |> startWith")
//}

public func combineLatest<T>(_ stream: Stream<T>) -> (_ upstream: Stream<T>) -> Stream<[T]> {
    return { (upstream: Stream<T>) in
        return upstream |> combineLatest([stream])
    }
}

public func combineLatest<T>(_ streams: [Stream<T>]) -> (_ upstream: Stream<T>) -> Stream<[T]> {
    return { (upstream: Stream<T>) in
        let stream = ([upstream] + streams) |> combineLatestAll
        return stream.name("\(upstream.name) |> combineLatest")
    }
}

public func zip<T>(_ stream: Stream<T>) -> (_ upstream: Stream<T>) -> Stream<[T]> {
    return { (upstream: Stream<T>) in
        return upstream |> zip([stream])
    }
}

public func zip<T>(_ streams: [Stream<T>]) -> (_ upstream: Stream<T>) -> Stream<[T]> {
    return { (upstream: Stream<T>) in
        let stream = ([upstream] + streams) |> zipAll
        return stream.name("\(upstream.name) |> zip")
    }
}

/// a.k.a Rx.catch
public func recover<T>(catchHandler: @escaping (Stream<T>.ErrorInfo) -> Stream<T>) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, nil, configure, canceller)
            
            upstream.react(&canceller) { value in
                progress(value)
            }.failure { errorInfo in
                let recoveryStream = catchHandler(errorInfo)
                
                var canceller2: Canceller? = nil
                _bindToUpstream(recoveryStream, fulfill, reject, configure, canceller2)
                
                recoveryStream.react(&canceller2) { value in
                    progress(value)
                }
            }
        }
    }
}

// MARK: timing

/// delay `progress` and `fulfill` for `timerInterval` seconds
public func delay<T>(_ timeInterval: TimeInterval) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, nil, reject, configure, canceller)
            
            upstream.react(&canceller) { value in
                var timerStream: Stream<Void>? = Timer.stream(timeInterval: timeInterval, repeats: false) { _ in }
                
                timerStream!.react { _ in
                    progress(value)
                    timerStream = nil
                }
            }.success { _ -> Void in
                var timerStream: Stream<Void>? = Timer.stream(timeInterval: timeInterval, repeats: false) { _ in }
                
                timerStream!.react { _ in
                    fulfill()
                    timerStream = nil
                }
            }
        }.name("\(upstream.name) |> delay(\(timeInterval))")
    }
}

/// delay `progress` and `fulfill` for `timerInterval * eachProgressCount` seconds
/// (incremental delay with start at t = 0sec)
public func interval<T>(_ timeInterval: TimeInterval) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, nil, reject, configure, canceller)
            
            var incInterval = 0.0
            
            upstream.react(&canceller) { value in
                var timerStream: Stream<Void>? = Timer.stream(timeInterval: incInterval, repeats: false) { _ in }
                
                incInterval += timeInterval
                
                timerStream!.react { _ in
                    progress(value)
                    timerStream = nil
                }
            }.success { _ -> Void in
                incInterval -= timeInterval - 0.01
                
                var timerStream: Stream<Void>? = Timer.stream(timeInterval: incInterval, repeats: false) { _ in }
                timerStream!.react { _ in
                    fulfill()
                    timerStream = nil
                }
            }
        }.name("\(upstream.name) |> interval(\(timeInterval))")
    }
}

/// limit continuous progress (reaction) for `timeInterval` seconds when first progress is triggered
/// (see also: underscore.js throttle)
public func throttle<T>(_ timeInterval: TimeInterval) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            var lastProgressDate = Date(timeIntervalSince1970: 0)
            
            upstream.react(&canceller) { value in
                let now = Date()
                let timeDiff = now.timeIntervalSince(lastProgressDate)
                
                if timeDiff > timeInterval {
                    lastProgressDate = now
                    progress(value)
                }
            }
        }.name("\(upstream.name) |> throttle(\(timeInterval))")
    }
}

/// delay progress (reaction) for `timeInterval` seconds and truly invoke reaction afterward if not interrupted by continuous progress
/// (see also: underscore.js debounce)
public func debounce<T>(_ timeInterval: TimeInterval) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, fulfill, reject, configure, canceller)
            
            var timerStream: Stream<Void>? = nil    // retained by upstream via upstream.react()
            
            upstream.react(&canceller) { value in
                // NOTE: overwrite to deinit & cancel old timerStream
                timerStream = Timer.stream(timeInterval: timeInterval, repeats: false) { _ in }
                
                timerStream!.react { _ in
                    progress(value)
                }
            }
        }.name("\(upstream.name) |> debounce(\(timeInterval))")
    }
}

// MARK: collecting

public func reduce<T, U>(_ initialValue: U, _ accumulateClosure: @escaping (_ accumulatedValue: U, _ newValue: T) -> U) -> (_ upstream: Stream<T>) -> Stream<U> {
    return { (upstream: Stream<T>) -> Stream<U> in
        return Stream<U> { progress, fulfill, reject, configure in
            let accumulatingStream = upstream
                |> mapAccumulate(initialValue, accumulateClosure)
            
            var canceller: Canceller? = nil
            _bindToUpstream(accumulatingStream, nil, nil, configure, canceller)
            
            var lastAccValue: U = initialValue   // last accumulated value
            
            accumulatingStream.react(&canceller) { value in
                lastAccValue = value
            }.then { value, errorInfo -> Void in
                if value != nil {
                    progress(lastAccValue)
                    fulfill()
                } else if let errorInfo = errorInfo {
                    if let error = errorInfo.error {
                        reject(error)
                    }
                    else {
                        let cancelError = _RKError(.cancelledByUpstream, "Upstream is cancelled before performing `reduce()`.")
                        reject(cancelError)
                    }
                }
            }
        }.name("\(upstream.name) |> reduce")
    }
}

// MARK: async

///
/// Wraps `upstream` to perform `dispatch_async(queue)` when it first starts running.
/// a.k.a. `Rx.subscribeOn`.
///
/// For example:
///
///   let downstream = upstream |> startAsync(queue) |> map {...A...}`
///   downstream ~> {...B...}`
///
/// 1. `~>` resumes `downstream` all the way up to `upstream`
/// 2. calls `dispatch_async(queue)` wrapping `upstream`
/// 3. A and B will run on `queue` rather than the thread `~>` was called
///
/// :NOTE 1:
/// `upstream` MUST NOT START `.Running` in order to safely perform `startAsync(queue)`.
/// If `upstream` is already running, `startAsync(queue)` will have no effect.
///
/// :NOTE 2:
/// `upstream |> startAsync(queue) ~> { ... }` is same as `dispatch_async(queue, { upstream ~> {...} })`,
/// but it guarantees the `upstream` to start on target `queue` if not started yet.
///
public func startAsync<T>(_ queue: DispatchQueue) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            queue.async() {
                var canceller: Canceller? = nil
                _bindToUpstream(upstream, fulfill, reject, configure, canceller)
                
                upstream.react(&canceller, reactClosure: progress)
            }
        }.name("\(upstream.name) |> startAsync(\(_queueLabel(queue)))")
    }
}

///
/// Performs `dispatch_async(queue)` to the consecutive pipelining operations.
/// a.k.a. `Rx.observeOn`.
/// 
/// For example:
///
///   let downstream = upstream |> map {...A...}` |> async(queue) |> map {...B...}`
///   downstream ~> {...C...}`
///
/// 1. `~>` resumes `downstream` all the way up to `upstream`
/// 2. `upstream` and A will run on the thread `~>` was called
/// 3. B and C will run on `queue`
///
/// - parameter queue: `dispatch_queue_t` to perform consecutive stream operations. Using concurrent queue is not recommended.
///
public func async<T>(_ queue: DispatchQueue) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, nil, nil, configure, canceller)
            
            let upstreamName = upstream.name
            
            upstream.react(&canceller) { value in
                queue.async() {
                    progress(value)
                }
            }.then { value, errorInfo -> Void in
                queue.async(flags: .barrier) {
                    _finishDownstreamOnUpstreamFinished(upstreamName, value, errorInfo, fulfill, reject)
                }
            }
        }.name("\(upstream.name))-async(\(_queueLabel(queue)))")
    }
}

///
/// - Experiment: async + backpressure using blocking semaphore
///
public func asyncBackpressureBlock<T>(_ queue: DispatchQueue, high highCountForPause: Int, low lowCountForResume: Int) -> (_ upstream: Stream<T>) -> Stream<T> {
    return { (upstream: Stream<T>) in
        return Stream<T> { progress, fulfill, reject, configure in
            var canceller: Canceller? = nil
            _bindToUpstream(upstream, nil, nil, configure, canceller)
            
            let upstreamName = upstream.name
            
            var count = 0
            var isBackpressuring = false
            let lock = NSRecursiveLock()
            let semaphore = DispatchSemaphore(value: 0)
            
            upstream.react(&canceller) { value in
                queue.async() {
                    progress(value)
                    
                    lock.lock()
                    count -= 1
                    let shouldResume = isBackpressuring && count <= lowCountForResume
                    if shouldResume {
                        isBackpressuring = false
                    }
                    lock.unlock()
                    
                    if shouldResume {
                        semaphore.signal()
                    }
                }
                
                lock.lock()
                count += 1
                let shouldPause = count >= highCountForPause
                if shouldPause {
                    isBackpressuring = true
                }
                lock.unlock()
                
                if shouldPause {
                    let _ = semaphore.wait(timeout: DispatchTime.distantFuture)
                }
            }.then { value, errorInfo -> Void in
                queue.async(flags: .barrier) {
                    _finishDownstreamOnUpstreamFinished(upstreamName, value, errorInfo, fulfill, reject)
                }
            }
        }.name("\(upstream.name))-async(\(_queueLabel(queue)))")
    }
}

//--------------------------------------------------
// MARK: - Array Streams Operations
//--------------------------------------------------

/// Merges multiple streams into single stream.
/// See also: mergeInner
public func mergeAll<T>(_ streams: [Stream<T>]) -> Stream<T> {
    let stream = Stream.sequence(streams) |> mergeInner
    return stream.name("mergeAll")
}

///
/// Merges multiple streams into single stream,
/// combining latest values `[T?]` as well as changed value `T` together as `([T?], T)` tuple.
///
/// This is a generalized method for `Rx.merge()` and `Rx.combineLatest()`.
///
public func merge2All<T>(_ streams: [Stream<T>]) -> Stream<(values: [T?], changedValue: T)> {
    var cancellers = [Canceller?](repeating: nil, count: streams.count)
    
    return Stream { progress, fulfill, reject, configure in
        configure.pause = {
            Stream<T>.pauseAll(streams)
        }
        configure.resume = {
            Stream<T>.resumeAll(streams)
        }
        configure.cancel = {
            Stream<T>.cancelAll(streams)
        }
        
        var states = [T?](repeating: nil, count: streams.count)
        
        for i in 0..<streams.count {
            let stream = streams[i]
            var canceller: Canceller? = nil
            
            stream.react(&canceller) { value in
                states[i] = value
                progress(values: states, changedValue: value)
            }.then { value, errorInfo -> Void in
                if value != nil {
                    fulfill()
                } else if let errorInfo = errorInfo {
                    if let error = errorInfo.error {
                        reject(error)
                    }
                    else {
                        let error = _RKError(.cancelledByInternalStream, "One of stream is cancelled in `merge2All()`.")
                        reject(error)
                    }
                }
            }
            
            cancellers += [canceller]
        }
    }.name("merge2All")
}

public func combineLatestAll<T>(_ streams: [Stream<T>]) -> Stream<[T]> {
    let stream = merge2All(streams)
        |> filter { values, _ in
            var areAllNonNil = true
            for value in values {
                if value == nil {
                    areAllNonNil = false
                    break
                }
            }
            return areAllNonNil
        }
        |> map { values, _ in values.map { $0! } }
    return stream.name("combineLatestAll")
}

public func zipAll<T>(_ streams: [Stream<T>]) -> Stream<[T]> {
    precondition(streams.count > 1)
    
    var cancellers = [Canceller?](repeating: nil, count: streams.count)
    
    return Stream<[T]> { progress, fulfill, reject, configure in
        configure.pause = {
            Stream<T>.pauseAll(streams)
        }
        configure.resume = {
            Stream<T>.resumeAll(streams)
        }
        configure.cancel = {
            Stream<T>.cancelAll(streams)
        }
        
        let streamCount = streams.count

        var storedValuesArray: [[T]] = []
        for _ in 0..<streamCount {
            storedValuesArray.append([])
        }
        
        for i in 0..<streamCount {
            var canceller: Canceller? = nil
            
            streams[i].react(&canceller) { value in
                storedValuesArray[i] += [value]
                
                var canProgress: Bool = true
                for storedValues in storedValuesArray {
                    if storedValues.count == 0 {
                        canProgress = false
                        break
                    }
                }
                
                if canProgress {
                    var firstStoredValues: [T] = []
                    
                    for i in 0..<streamCount {
                        let firstStoredValue = storedValuesArray[i].remove(at: 0)
                        firstStoredValues.append(firstStoredValue)
                    }
                    
                    progress(firstStoredValues)
                }
            }.success { _ -> Void in
                fulfill()
            }
            cancellers += [canceller]
        }
    }.name("zipAll")
}

//--------------------------------------------------
// MARK: - Nested Stream Operations (flattening)
//--------------------------------------------------

public enum FlattenStyle: String, CustomStringConvertible {
    case merge = "Merge"
    case concat = "Concat"
    case latest = "Latest"
    
    public var description: String { return self.rawValue }
}

public func flatten<T>(_ style: FlattenStyle) -> (_ upstream: Stream<Stream<T>>) -> Stream<T> {
    switch style {
        case .merge: return mergeInner
        case .concat: return concatInner
        case .latest: return switchLatestInner
    }
}

///
/// Merges multiple streams into single stream.
///
/// - e.g. `let mergedStream = [stream1, stream2, ...] |> mergeInner`
///
public func mergeInner<T>(_ upstream: Stream<Stream<T>>) -> Stream<T> {
    return Stream<T> { progress, fulfill, reject, configure in
        var unfinishedCount = 1
        let lock = NSRecursiveLock()
        
        let fulfillIfPossible: () -> Void = {
            lock.lock()
            unfinishedCount -= 1
            if unfinishedCount == 0 {
                fulfill()
            }
            lock.unlock()
        }
        
        var canceller: Canceller? = nil
        _bindToUpstream(upstream, nil, reject, configure, canceller)
        
        upstream.react(&canceller) { (innerStream: Stream<T>) in
            lock.lock()
            unfinishedCount += 1
            lock.unlock()
            
            var innerCanceller: Canceller? = nil
            _bindToUpstream(innerStream, nil, nil, configure, innerCanceller)

            innerStream.react(&innerCanceller) { value in
                progress(value)
            }.then { value, errorInfo -> Void in
                if value != nil {
                    fulfillIfPossible()
                } else if let errorInfo = errorInfo {
                    if let error = errorInfo.error {
                        reject(error)
                    }
                    else {
                        let error = _RKError(.cancelledByInternalStream, "One of the inner stream in `mergeInner()` is cancelled.")
                        reject(error)
                    }
                }
            }
        }.success {
            fulfillIfPossible()
        }
    }.name("mergeInner")
}

public func concatInner<T>(_ upstream: Stream<Stream<T>>) -> Stream<T> {
    return Stream<T> { progress, fulfill, reject, configure in
        var pendingInnerStreams = [Stream<T>]()
        
        var unfinishedCount = 1
        let lock = NSRecursiveLock()
        
        let fulfillIfPossible: () -> Void = {
            lock.lock()
            unfinishedCount -= 1
            if unfinishedCount == 0 {
                fulfill()
            }
            lock.unlock()
        }
        
        let performRecursively: () -> Void = _fix { recurse in
            return {
                if let innerStream = pendingInnerStreams.first {
                    var innerCanceller: Canceller? = nil
                    _bindToUpstream(innerStream, nil, nil, configure, innerCanceller)
                    
                    innerStream.react(&innerCanceller) { value in
                        progress(value)
                    }.then { value, errorInfo -> Void in
                        if value != nil {
                            lock.lock()
                            pendingInnerStreams.remove(at: 0)
                            recurse()
                            lock.unlock()
                            
                            fulfillIfPossible()
                        }
                        else if let errorInfo = errorInfo {
                            if let error = errorInfo.error {
                                reject(error)
                            }
                            else {
                                let error = _RKError(.cancelledByInternalStream, "One of the inner stream in `concatInner()` is cancelled.")
                                reject(error)
                            }
                        }
                    }
                }
            }
        }
        
        var canceller: Canceller? = nil
        _bindToUpstream(upstream, nil, reject, configure, canceller)
        
        upstream.react(&canceller) { (innerStream: Stream<T>) in
            lock.lock()
            unfinishedCount += 1
            
            pendingInnerStreams += [innerStream]
            if pendingInnerStreams.count == 1 {
                performRecursively()
            }
            lock.unlock()
        }.success { _ -> Void in
            fulfillIfPossible()
        }
    }.name("concatInner")
}

/// uses the latest innerStream and cancels previous innerStreams
/// a.k.a Rx.switchLatest
public func switchLatestInner<T>(_ upstream: Stream<Stream<T>>) -> Stream<T> {
    return Stream<T> { progress, fulfill, reject, configure in
        var currentInnerStream: Stream<T>?
        
        var unfinishedCount = 1
        let lock = NSRecursiveLock()
        
        let finishIfPossible: (@escaping () -> Void) -> () -> Void = { finish in
            return {
                lock.lock()
                unfinishedCount -= 1
                if unfinishedCount == 0 {
                    finish()
                }
                lock.unlock()
            }
        }
        let fulfillIfPossible = finishIfPossible { fulfill() }
        let rejectIfPossible = finishIfPossible {
            let error = _RKError(.cancelledByInternalStream, "Last inner stream in `switchLatestInner()` is cancelled.")
            reject(error)
        }
        
        var canceller: Canceller? = nil
        _bindToUpstream(upstream, nil, reject, configure, canceller)
        
        upstream.react(&canceller) { (innerStream: Stream<T>) in
            lock.lock()
            unfinishedCount += 1
            lock.unlock()
            
            currentInnerStream?.cancel()
            currentInnerStream = innerStream
            
            var innerCanceller: Canceller? = nil
            _bindToUpstream(innerStream, nil, nil, configure, innerCanceller)
            
            innerStream.react(&innerCanceller) { value in
                progress(value)
            }.then { value, errorInfo -> Void in
                if value != nil {
                    fulfillIfPossible()
                } else if let errorInfo = errorInfo {
                    if let error = errorInfo.error {
                        reject(error)
                    }
                    else {
                        rejectIfPossible()  // will reject if upstream finished & last innerStream is cancelled
                    }
                }
            }
        }.success { _ -> Void in
            fulfillIfPossible()
        }
    }.name("switchLatestInner")
}

//--------------------------------------------------
// MARK: - Stream Producer Operations
//--------------------------------------------------

///
/// Creates an upstream from `upstreamProducer`, resumes it (prestart),
/// and caches its emitted values (`capacity` as max buffer count) for future "replay"
/// when returning streamProducer creates a new stream & resumes it,
/// a.k.a. Rx.replay().
///
/// NOTE: `downstream`'s `pause()`/`resume()`/`cancel()` will not affect `upstream`.
///
/// :Usage:
///     let cachedStreamProducer = networkStream |>> prestart(capacity: 1)
///     let cachedStream1 = cachedStreamProducer()
///     cachedStream1 ~> { ... }
///     let cachedStream2 = cachedStreamProducer() // can produce many cached streams
///     ...
///
/// - parameter capacity: max buffer count for prestarted stream
///
public func prestart<T>(capacity: Int = Int.max) -> (_ upstreamProducer: Stream<T>.Producer) -> Stream<T>.Producer {
    return { (upstreamProducer: Stream<T>.Producer) -> Stream<T>.Producer in
        var buffer = [T]()
        let upstream = upstreamProducer()
        
        // REACT
        upstream.react { value in
            buffer += [value]
            while buffer.count > capacity {
                buffer.remove(at: 0)
            }
        }
        
        return {
            return Stream<T> { progress, fulfill, reject, configure in
                var canceller: Canceller? = nil
                _bindToUpstream(upstream, fulfill, reject, configure, canceller)
                
                for b in buffer {
                    progress(b)
                }
                
                upstream.react(&canceller) { value in
                    progress(value)
                }
            }
        }
    }
}

/// a.k.a Rx.repeat
public func times<T>(_ repeatCount: Int) -> (_ upstreamProducer: Stream<T>.Producer) -> Stream<T>.Producer {
    return { (upstreamProducer: @escaping Stream<T>.Producer) -> Stream<T>.Producer in
        if repeatCount <= 0 {
            return { Stream.empty() }
        }
        
        if repeatCount == 1 {
            return upstreamProducer
        }
        
        return {
            return Stream<T> { progress, fulfill, reject, configure in
                var countDown = repeatCount
                
                let performRecursively: () -> Void = _fix { recurse in
                    return {
                        let upstream = upstreamProducer()
                        
                        var canceller: Canceller? = nil
                        _bindToUpstream(upstream, nil, reject, configure, canceller)
                        
                        upstream.react(&canceller) { value in
                            progress(value)
                        }.success { _ -> Void in
                            countDown -= 1
                            countDown > 0 ? recurse() : fulfill()
                        }
                    }
                }

                performRecursively()
            }
        }
    } as! (() -> Stream<T>) -> () -> Stream<T>
}

public func retry<T>(_ retryCount: Int) -> (_ upstreamProducer: @escaping Stream<T>.Producer) -> Stream<T>.Producer {
    precondition(retryCount >= 0)
    
    return { (upstreamProducer: @escaping Stream<T>.Producer) in
        if retryCount == 0 {
            return upstreamProducer
        } else {
            return upstreamProducer |>> recover { _ -> Stream<T> in
                return retry(retryCount - 1)(upstreamProducer)()
            }
        }
    }
}

//--------------------------------------------------
/// MARK: - Rx Semantics
/// (TODO: move to new file, but doesn't work in Swift 1.1. ERROR = ld: symbol(s) not found for architecture x86_64)
//--------------------------------------------------

public extension Stream {
    /// alias for `Stream.fulfilled()`
    public class func just(value: T) -> Stream<T> {
        return self.once(value)
    }
    
    /// alias for `Stream.fulfilled()`
    public class func empty() -> Stream<T> {
        return self.fulfilled()
    }
    
    /// alias for `Stream.rejected()`
    public class func error(error: Error) -> Stream<T> {
        return self.rejected(error)
    }
}

/// alias for `mapAccumulate()`
public func scan<T, U>(_ initialValue: U, _ accumulateClosure: @escaping (_ accumulatedValue: U, _ newValue: T) -> U) -> (_ upstream: Stream<T>) -> Stream<U> {
    return { (upstream: Stream<T>) in
        return mapAccumulate(initialValue, accumulateClosure)(upstream)
    }
}

/// alias for `prestart()`
public func replay<T>(capacity: Int = Int.max) -> (_ upstreamProducer: Stream<T>.Producer) -> Stream<T>.Producer {
    return prestart(capacity: capacity)
}

//--------------------------------------------------
// MARK: - Custom Operators
// + - * / % = < > ! & | ^ ~ .
//--------------------------------------------------

// MARK: |> (stream pipelining)

precedencegroup StreamPipeliningPrecedence {
    associativity: left
}

infix operator |>: StreamPipeliningPrecedence

/// single-stream pipelining operator
public func |> <T, U>(stream: Stream<T>, transform: (Stream<T>) -> Stream<U>) -> Stream<U> {
    return transform(stream)
}

/// array-streams pipelining operator
public func |> <T, U, S: Sequence>(streams: S, transform: (S) -> Stream<U>) -> Stream<U> where S.Iterator.Element == Stream<T> {
    return transform(streams)
}

/// nested-streams pipelining operator
public func |> <T, U, S: Sequence>(streams: S, transform: (Stream<Stream<T>>) -> Stream<U>) -> Stream<U> where S.Iterator.Element == Stream<T> {
    return transform(Stream.sequence(streams))
}

/// stream-transform pipelining operator
public func |> <T, U, V>(transform1: @escaping (Stream<T>) -> Stream<U>, transform2: @escaping (Stream<U>) -> Stream<V>) -> (Stream<T>) -> Stream<V> {
    return { transform2(transform1($0)) }
}

// MARK: |>> (streamProducer pipelining)

infix operator |>>

/// streamProducer lifting & pipelining operator
public func |>> <T, U>(streamProducer: @escaping Stream<T>.Producer, transform: @escaping (Stream<T>) -> Stream<U>) -> Stream<U>.Producer {
    return { transform(streamProducer()) }
}

/// streamProducer(autoclosured) lifting & pipelining operator
public func |>> <T, U>(streamProducer: @autoclosure @escaping () -> Stream<T>, transform: @escaping (Stream<T>) -> Stream<U>) -> Stream<U>.Producer {
    return { transform(streamProducer()) }
}

/// streamProducer pipelining operator
public func |>> <T, U>(streamProducer: Stream<T>.Producer, transform: (Stream<T>.Producer) -> Stream<U>.Producer) -> Stream<U>.Producer {
    return transform(streamProducer)
}

/// streamProducer(autoclosured) pipelining operator
public func |>> <T, U>(streamProducer: @autoclosure @escaping () -> Stream<T>, transform: (Stream<T>.Producer) -> Stream<U>.Producer) -> Stream<U>.Producer {
    return transform(streamProducer)
}

/// streamProducer-transform pipelining operator
public func |>> <T, U, V>(transform1: @escaping (Stream<T>.Producer) -> Stream<U>.Producer, transform2: @escaping (Stream<U>.Producer) -> Stream<V>.Producer) -> (Stream<T>.Producer) -> Stream<V>.Producer {
    return { transform2(transform1($0)) }
}

// MARK: ~> (right reacting operator)

///
/// Right-closure reacting operator,
/// e.g. `stream ~> { ... }`.
///
/// This method returns Canceller for removing `reactClosure`.
///
@discardableResult public func ~> <T>(stream: Stream<T>, reactClosure: @escaping (T) -> Void) -> Canceller? {
    var canceller: Canceller? = nil
    stream.react(&canceller, reactClosure: reactClosure)
    return canceller
}

// MARK: <~ (left reacting operator)

precedencegroup LeftReactingPrecedence {
    associativity: right
}

infix operator <~ : LeftReactingPrecedence

///
/// Left-closure (closure-first) reacting operator, reversing `stream ~> { ... }`
/// e.g. `^{ ... } <~ stream`
///
/// This method returns Canceller for removing `reactClosure`.
///
@discardableResult public func <~ <T>(reactClosure: @escaping (T) -> Void, stream: Stream<T>) -> Canceller? {
    return stream ~> reactClosure
}

// MARK: ~>! (terminal reacting operator)

infix operator ~>!

///
/// Terminal reacting operator, which returns synchronously-emitted last value
/// to gain similar functionality as Java 8's Stream API,
///
/// e.g. 
/// - let sum = Stream.sequence([1, 2, 3]) |> reduce(0) { $0 + $1 } ~>! ()
/// - let distinctSequence = Stream.sequence([1, 2, 2, 3]) |> distinct |> buffer() ~>! ()
///
/// NOTE: use `buffer()` as collecting operation whenever necessary
///
@discardableResult public func ~>! <T>(stream: Stream<T>, void: Void) -> T! {
    var ret: T!
    stream.react { value in
        ret = value
    }
    return ret
}

/// terminal reacting operator (less precedence for '~>')
@discardableResult public func ~>! <T>(stream: Stream<T>, reactClosure: @escaping (T) -> Void) -> Canceller? {
    return stream ~> reactClosure
}

prefix operator ^

/// Objective-C like 'block operator' to let Swift compiler know closure-type at start of the line
/// e.g. ^{ print($0) } <~ stream
public prefix func ^ <T, U>(closure: @escaping (T) -> U) -> ((T) -> U) {
    return closure
}

//--------------------------------------------------
// MARK: - Utility
//--------------------------------------------------

internal struct _InfiniteIterator<T>: IteratorProtocol {
    let initialValue: T
    let nextClosure: (T) -> T
    
    var currentValue: T?
    
    init(initialValue: T, nextClosure: @escaping (T) -> T) {
        self.initialValue = initialValue
        self.nextClosure = nextClosure
    }
    
    mutating func next() -> T? {
        if let currentValue = self.currentValue {
            self.currentValue = self.nextClosure(currentValue)
        } else {
            self.currentValue = self.initialValue
        }
        
        return self.currentValue
    }
}

/// fixed-point combinator
internal func _fix<T, U>(_ f: @escaping (@escaping (T) -> U) -> (T) -> U) -> (T) -> U {
    return { f(_fix(f))($0) }
}

internal func _summary<T>(_ type: T) -> String {
    return Mirror(reflecting: type).description.characters.split(separator: ".").map { String($0) }.last ?? "?"
}

internal func _queueLabel(_ queue: DispatchQueue) -> String {
    return queue.label.characters.split(separator: ".").map { String($0) }.last ?? "?"
}


///
/// Helper method to bind downstream's `fulfill`/`reject`/`configure` handlers to `upstream`.
///
/// - parameter upstream: upstream to be bound to downstream
/// - parameter downstreamFulfill: `downstream`'s `fulfill`
/// - parameter downstreamReject: `downstream`'s `reject`
/// - parameter downstreamConfigure: `downstream`'s `configure`
/// - parameter reactCanceller: `canceller` used in `upstream.react(&canceller)` (`@autoclosure(escaping)` for lazy evaluation)
///
private func _bindToUpstream<T, C: Canceller>(_ upstream: Stream<T>, _ downstreamFulfill: (() -> Void)?, _ downstreamReject: ((Error) -> Void)?, _ downstreamConfigure: TaskConfiguration?, _ reactCanceller: @autoclosure @escaping () -> C?) {
    //
    // NOTE:
    // Bind downstream's `configure` to upstream
    // BEFORE performing its `progress()`/`then()`/`success()`/`failure()`
    // so that even when downstream **immediately finishes** on its 1st resume,
    // upstream can know `configure.isFinished = true`
    // while performing its `initClosure`.
    //
    // This is especially important for stopping immediate-infinite-sequence,
    // e.g. `infiniteStream.take(3)` will stop infinite-while-loop at end of 3rd iteration.
    //
    
    // NOTE: downstream should capture upstream
    if let downstreamConfigure = downstreamConfigure {
        let oldPause = downstreamConfigure.pause
        downstreamConfigure.pause = {
            oldPause?()
            upstream.pause()
        }
        
        let oldResume = downstreamConfigure.resume
        downstreamConfigure.resume = {
            oldResume?()
            upstream.resume()
        }
        
        // NOTE: `configure.cancel()` is always called on downstream-finish
        let oldCancel = downstreamConfigure.cancel
        downstreamConfigure.cancel = {
            oldCancel?()
            
            let canceller = reactCanceller()
            canceller?.cancel()
            upstream.cancel()
        }
    }
    
    if downstreamFulfill != nil || downstreamReject != nil {
        let upstreamName = upstream.name
        
        // fulfill/reject downstream on upstream-fulfill/reject/cancel
        upstream.then { value, errorInfo -> Void in
            _finishDownstreamOnUpstreamFinished(upstreamName, value, errorInfo, downstreamFulfill, downstreamReject)
        }
    }
}

/// helper method to send upstream's fulfill/reject to downstream
private func _finishDownstreamOnUpstreamFinished(_ upstreamName: String, _ upstreamValue: Void?, _ upstreamErrorInfo: Stream<Void>.ErrorInfo?, _ downstreamFulfill: (() -> Void)?, _ downstreamReject: ((Error) -> Void)?) {
    if upstreamValue != nil {
        downstreamFulfill?()
    } else if let upstreamErrorInfo = upstreamErrorInfo {
        // rejected
        if let upstreamError = upstreamErrorInfo.error {
            downstreamReject?(upstreamError)
        } else { // cancelled
            let cancelError = _RKError(.cancelledByUpstream, "Upstream=\(upstreamName) is rejected or cancelled.")
            downstreamReject?(cancelError)
        }
    }
}
