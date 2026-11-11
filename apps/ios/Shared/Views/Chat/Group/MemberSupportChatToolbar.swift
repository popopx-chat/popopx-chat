//
//  MemberSupportChatToolbar.swift
//  POPOPX (iOS)
//
//  Created by spaced4ndy on 01.05.2025.
//  Copyright © 2025 POPOPX Chat. All rights reserved.
//

import SwiftUI
import POPOPXChat

struct MemberSupportChatToolbar: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var theme: AppTheme
    var groupMember: GroupMember
    var imageSize: CGFloat = 32
    
    var body: some View {
        return HStack {
            MemberProfileImage(groupMember, size: imageSize)
                .padding(.trailing, 4)
            let t = Text(groupMember.chatViewName).font(.headline)
            NameWithBadge((groupMember.verified ? memberVerifiedShield + t : t), groupMember.nameBadge, .headline)
                .lineLimit(1)
        }
        .foregroundColor(theme.colors.onBackground)
        .frame(width: 220)
    }

    private var memberVerifiedShield: Text {
        (Text(Image(systemName: "checkmark.shield")) + textSpace)
            .font(.caption)
            .foregroundColor(theme.colors.secondary)
            .baselineOffset(1)
            .kerning(-2)
    }
}

struct MemberSupportChatToolbar_Previews: PreviewProvider {
    static var previews: some View {
        MemberSupportChatToolbar(
            groupMember: GroupMember.sampleData
        )
        .environmentObject(CurrentColors.toAppTheme())
    }
}
