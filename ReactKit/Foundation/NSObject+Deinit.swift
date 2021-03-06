//
//  NSObject+Deinit.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/09/14.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import Foundation

private var deinitStreamKey: UInt8 = 0

public extension NSObject {
    private var _deinitStream: Stream<Any?>? {
        get {
            return objc_getAssociatedObject(self, &deinitStreamKey) as? Stream<Any?>
        }
        set {
            objc_setAssociatedObject(self, &deinitStreamKey, newValue, .OBJC_ASSOCIATION_RETAIN)  // not OBJC_ASSOCIATION_RETAIN_NONATOMIC
        }
    }
    
    public var deinitStream: Stream<Any?> {
        var stream: Stream<Any?>? = self._deinitStream
        
        if stream == nil {
            stream = Stream<Any?> { (progress, fulfill, reject, configure) in
                // do nothing
            }.name("\(_summary(self)).deinitStream")
            
//            #if DEBUG
//                stream?.then { value, errorInfo -> Void in
//                    print("[internal] deinitStream finished")
//                }
//            #endif
            
            self._deinitStream = stream
        }
        
        return stream!
    }
}
