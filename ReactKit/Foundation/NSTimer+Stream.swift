//
//  NSTimer+Stream.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/10/07.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import Foundation

public extension Timer
{
    public class func stream<T>(timeInterval: TimeInterval, userInfo: AnyObject? = nil, repeats: Bool = true, map: (Timer?) -> T) -> Stream<T>
    {
        return Stream { progress, fulfill, reject, configure in
            
            let target = _TargetActionProxy { (self_: AnyObject?) in
                progress(map(self_ as? Timer))
                
                if !repeats {
                    fulfill()
                }
            }
            
            var timer: Timer?
            
            configure.pause = {
                timer?.invalidate()
                timer = nil
            }
            configure.resume = {
                if timer == nil {
                    timer = Timer(timeInterval: timeInterval, target: target, selector: _targetActionSelector, userInfo: userInfo, repeats: repeats)
                    RunLoop.current().add(timer!, forMode: RunLoopMode.commonModes)
                }
            }
            configure.cancel = {
                timer?.invalidate()
                timer = nil
            }
            
            configure.resume?()
            
        }.name("\(_summary(self))")
    }
}
