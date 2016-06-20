//
//  NSIndexSet+Helper.swift
//  ReactKit
//
//  Created by Yasuhiro Inami on 2015/03/21.
//  Copyright (c) 2015年 Yasuhiro Inami. All rights reserved.
//

import Foundation

extension NSIndexSet
{
    public convenience init<S: Sequence where S.Iterator.Element == Int>(indexes: S)
    {
        let indexSet = NSMutableIndexSet()
        for index in indexes {
            indexSet.add(index)
        }
        
        self.init(indexSet: indexSet as IndexSet)
    }
}
