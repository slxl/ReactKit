//
//  Error.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/12/02.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import Foundation

public enum ReactKitError: Int {
    public static let Domain = "ReactKitErrorDomain"
    
    case cancelled = 0
    case cancelledByDeinit = 1
    case cancelledByUpstream = 2
    case cancelledByTriggerStream = 3
    case cancelledByInternalStream = 4
    
    case rejectedByInternalTask = 1000
}

/// helper
internal func _RKError(_ error: ReactKitError, _ localizedDescriptionKey: String) -> NSError {
    return NSError(
        domain: ReactKitError.Domain,
        code: error.rawValue,
        userInfo: [
            NSLocalizedDescriptionKey : localizedDescriptionKey
        ]
    )
}
