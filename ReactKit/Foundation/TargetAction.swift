//
//  TargetAction.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/10/03.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import Foundation

internal let _targetActionSelector = #selector(_TargetActionProxy.fire)

internal class _TargetActionProxy {
    // NOTE: can't use generics
    internal typealias T = Any
    internal typealias Handler = (T) -> Void
    internal var handler: Handler
    
    internal init(handler: Handler) {
        self.handler = handler
    }

    @objc func fire(sender: T) {
        self.handler(sender)
    }
}
