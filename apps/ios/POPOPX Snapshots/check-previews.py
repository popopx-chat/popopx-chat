#!/usr/bin/env python3

import re
import sys
from pathlib import Path

EXCLUDED = {
    "AppearanceSettings_Previews",
    "BadgesChooseBadgeView_Previews",
    "ChannelKeyManagementView_Previews",
    "ChatsListViewDark_Previews",
    "ChatsListView_Previews",
    "MainTabView_Previews",
    "MigrateFromDevice_Previews",
    "NewChatView_Previews",
    "PopopxAddFriendView_Previews",
    "PopopxAntiPhotoGallery_Previews",
    "PopopxBadgeCapsuleDark_Previews",
    "PopopxBadgeCapsuleLight_Previews",
    "PopopxBadgeCreditExchangeDark_Previews",
    "PopopxBadgeCreditExchangeLight_Previews",
    "PopopxBadgeDetailDark_Previews",
    "PopopxBadgeDetailLight_Previews",
    "PopopxBadgePaywallDark_Previews",
    "PopopxBadgePaywallLight_Previews",
    "PopopxBubbleGallery_Previews",
    "PopopxCabinChannelsView_Previews",
    "PopopxCabinHallView_Previews",
    "PopopxCabinView_Previews",
    "PopopxChannelSubscriptionSheetDark_Previews",
    "PopopxChannelSubscriptionSheetLight_Previews",
    "PopopxChannelThresholdViewDark_Previews",
    "PopopxChannelThresholdViewLight_Previews",
    "PopopxChatInfoView_Previews",
    "PopopxCommerceCardsDark_Previews",
    "PopopxContactsView_Previews",
    "PopopxControlsGallery_Previews",
    "PopopxCreateGroupView_Previews",
    "PopopxCreditsStoreDark_Previews",
    "PopopxCreditsStoreLight_Previews",
    "PopopxDisplayLanguageView_Previews",
    "PopopxGiftBadgeCardSheetDark_Previews",
    "PopopxGiftBadgeCardSheetLight_Previews",
    "PopopxGroupChatInfoView_Previews",
    "PopopxGroupsPage_Previews",
    "PopopxHelpView_Previews",
    "PopopxLocationPickerSheet_Previews",
    "PopopxMeViewPopulated_Previews",
    "PopopxMeView_Previews",
    "PopopxNewConnectionsPage_Previews",
    "PopopxProximityPreviewHost_Previews",
    "PopopxQRCardSheet_Previews",
    "PopopxSecureCardBubbleStates_Previews",
    "PopopxSendRedPacketSheetDark_Previews",
    "PopopxSendRedPacketSheetLight_Previews",
    "PopopxSettingsView_Previews",
    "PopopxTelemetryHeaderBluetoothOff_Previews",
    "PopopxTelemetryHeaderCellular_Previews",
    "PopopxTelemetryHeaderOnline_Previews",
    "PopopxTelemetryHeaderProximityOnly_Previews",
    "PopopxThemeGallery_Previews",
    "PopopxTrialWelcomeDormant_Previews",
    "PopopxTrialWelcomeLight_Previews",
    "PopopxVoucherRedeemSheetDark_Previews",
    "PopopxVoucherRedeemSheetLight_Previews",
    "ProfileBuilderView_Previews",
    "ProfileCardBubbleView_Previews",
    "ProfileQRCodeSheet_Previews",
    "ProfileSendModeSheet_Previews",
    "ServersSummaryView_Previews",
    "TerminalView_Previews",
    "UserProfilesView_Previews",
}

tests = Path(__file__).with_name("SnapshotTests.swift")
ios = tests.parents[1]
listed = set(re.findall(r"SnapshotScene\((\w+)\.self", tests.read_text()))
errors = []
for path in sorted(ios.rglob("*.swift")):
    source = path.read_text()
    name = path.relative_to(ios.parent.parent)
    for preview in re.findall(r"^[ \t]*struct[ \t]+(\w+)[ \t]*:[ \t]*PreviewProvider\b", source, re.M):
        if preview not in listed and preview not in EXCLUDED:
            errors.append(f"{name}: {preview} is not in previewScenes() of {tests.name}")
    if re.search(r"^[ \t]*#Preview\b", source, re.M):
        errors.append(f"{name}: #Preview is not rendered, write a PreviewProvider and add it to previewScenes() of {tests.name}")
print("\n".join(errors) or f"{len(listed)} previews are rendered, {len(EXCLUDED)} are excluded")
sys.exit(1 if errors else 0)
