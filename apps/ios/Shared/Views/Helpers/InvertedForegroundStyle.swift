//
//  Test.swift
//  POPOPX (iOS)
//
//  Created by Levitating Pineapple on 31/08/2024.
//  Copyright © 2024 POPOPX Chat. All rights reserved.
//

import SwiftUI

extension View {
    @ViewBuilder
    func invertedForegroundStyle(enabled: Bool = true) -> some View {
        if enabled {
            foregroundStyle(Material.ultraThin)
                .environment(\.colorScheme, .dark)
                .grayscale(1)
                .contrast(-20)
        } else { self }
    }
}
