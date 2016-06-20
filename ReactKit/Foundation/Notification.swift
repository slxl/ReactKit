//
//  Notification.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2014/09/11.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import Foundation

public extension NotificationCenter
{
    /// creates new Stream
    public func stream(notificationName: Foundation.Notification.Name, object: AnyObject? = nil, queue: OperationQueue? = nil) -> Stream<Foundation.Notification?>
    {
        return Stream { [weak self] progress, fulfill, reject, configure in
            
            var observer: NSObjectProtocol?
            
            configure.pause = {
                if let self_ = self {
                    if let observer_ = observer {
                        self_.removeObserver(observer_)
                        observer = nil
                    }
                }
            }
            configure.resume = {
                if let self_ = self {
                    if observer == nil {
                        observer = self_.addObserver(forName: notificationName, object: object, queue: queue) { notification in
                            progress(notification)
                        }
                    }
                }
            }
            configure.cancel = {
                if let self_ = self {
                    if let observer_ = observer {
                        self_.removeObserver(observer_)
                        observer = nil
                    }
                }
            }
            
            configure.resume?()
            
        }.name("NSNotification.stream(\(notificationName))") |> takeUntil(self.deinitStream)
    }
}

/// NSNotificationCenter helper
public struct Notification
{
    public static func stream(_ notificationName: Foundation.Notification.Name, _ object: AnyObject?) -> Stream<Foundation.Notification?>
    {
        return NotificationCenter.default().stream(notificationName: notificationName, object: object)
    }
    
    public static func post(_ notificationName: Foundation.Notification.Name, _ object: AnyObject?)
    {
        NotificationCenter.default().post(name: notificationName, object: object)
    }
}
