//
//  G7DeviceStatus.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 10/23/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

#if os(iOS)

import LoopKit
import LoopKitUI

public struct G7DeviceStatusHighlight: DeviceStatusHighlight, Equatable {
    public let localizedMessage: String
    public let imageName: String
    public let state: DeviceStatusHighlightState
    init(localizedMessage: String, imageName: String, state: DeviceStatusHighlightState) {
        self.localizedMessage = localizedMessage
        self.imageName = imageName
        self.state = state
    }
}

#endif
