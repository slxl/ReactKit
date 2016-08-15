//
//  NSObject+Owner.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/11/11.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import Foundation

private var owningStreamsKey: UInt8 = 0

internal extension NSObject {
    internal typealias AnyStream = Any // NOTE: can't use Stream<Any?>
    
    internal var _owningStreams: [AnyStream] {
        get {
            var owningStreams = objc_getAssociatedObject(self, &owningStreamsKey) as? [AnyStream]
            if owningStreams == nil {
                owningStreams = []
                self._owningStreams = owningStreams!
            }
            return owningStreams!
        }
        set {
            objc_setAssociatedObject(self, &owningStreamsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
