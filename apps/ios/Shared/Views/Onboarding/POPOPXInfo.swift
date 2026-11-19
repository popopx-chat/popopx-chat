//
//  POPOPXInfo.swift
//  POPOPX (iOS)
//
//  Created by Evgeny on 07/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//
// Spec: spec/client/navigation.md

import SwiftUI
import POPOPXChat

// Spec: spec/client/navigation.md#POPOPXInfo
// 引导第 1 屏：品牌宣言页。同一份视图也被「设置 → 关于」以 `onboarding: false` 复用，
// 所以只有 CTA 与徽章脚注受 `onboarding` 控制，其余两态共用。
struct POPOPXInfo: View {
    @EnvironmentObject var m: ChatModel
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onboarding: Bool

    @State private var createProfileNavLinkActive = false
    @State private var haloBreathing = false

    private static let haloDuration = 2.6
    private static let wordmarkMaxWidth: CGFloat = 236
    private static let haloSize = CGSize(width: 268, height: 152)

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .center, spacing: PopopxMetrics.spaceL) {
                    hero
                        .padding(.top, PopopxMetrics.spaceXL)
                    headlines
                    pills
                    featureCard
                    if onboarding {
                        actions
                    }
                }
                .padding(.bottom, PopopxMetrics.space2XL)
                .frame(maxWidth: .infinity, minHeight: g.size.height)
            }
        }
        .background(PopopxPalette.base, ignoresSafeAreaEdges: .all)
        .sheet(isPresented: Binding(
            get: { m.migrationState != nil && !createProfileNavLinkActive },
            set: { _ in
                m.migrationState = nil
                MigrationToDeviceState.save(nil) }
        )) {
            NavigationStack {
                VStack(alignment: .leading) {
                    MigrateToDevice(migrationState: $m.migrationState)
                }
                .navigationTitle("Migrate here")
                .modifier(ThemedBackground(grouped: true))
            }
        }
        .onAppear {
            setLastVersionDefault()
            startHalo()
        }
        .frame(maxHeight: .infinity)
        .navigationBarHidden(onboarding)
    }

    // MARK: - 视觉

    private var hero: some View {
        ZStack {
            Ellipse()
                .fill(PopopxPalette.brand.opacity(0.20))
                .frame(width: Self.haloSize.width, height: Self.haloSize.height)
                .blur(radius: 38)
                .scaleEffect(haloBreathing ? 1.06 : 0.94)
                .accessibilityHidden(true)
            Image(PopopxBrandAsset.wordmark(for: colorScheme))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.wordmarkMaxWidth)
                .accessibilityLabel(Text(verbatim: "POPOPX"))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var headlines: some View {
        VStack(alignment: .center, spacing: PopopxMetrics.spaceXS) {
            Text(PopopxOnboardingCopy.heroTitle)
                .font(PopopxType.display)
                .multilineTextAlignment(.center)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(PopopxOnboardingCopy.heroNote)
                .font(PopopxType.secondary)
                .multilineTextAlignment(.center)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .accessibilityElement(children: .combine)
    }

    private var pills: some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            modePill(
                systemImage: "lock.shield.fill",
                tint: .brand,
                label: PopopxOnboardingCopy.pillSMP
            )
            modePill(
                systemImage: "dot.radiowaves.left.and.right",
                tint: .mesh,
                label: PopopxOnboardingCopy.pillMesh
            )
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private func modePill(systemImage: String, tint: PopopxIconTint, label: String) -> some View {
        HStack(alignment: .center, spacing: PopopxMetrics.space2XS) {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .foregroundStyle(tint.fill)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(tint.fill.opacity(0.14), in: .rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
            Text(label)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.label)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(PopopxMetrics.space2XS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxMaterial.chip, in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .accessibilityElement(children: .combine)
    }

    private var featureCard: some View {
        PopopxSectionCard(
            PopopxOnboardingCopy.givesYou,
            footnote: onboarding ? PopopxOnboardingCopy.trialBadgeNote : nil
        ) {
            featureRow(
                systemImage: "person.crop.circle.badge.questionmark",
                tint: .brand,
                title: PopopxOnboardingCopy.noUserIDsTitle,
                note: PopopxOnboardingCopy.noUserIDsNote
            )
            PopopxOnboardingHairline()
            featureRow(
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: .mesh,
                title: PopopxOnboardingCopy.relaysTitle,
                note: PopopxOnboardingCopy.relaysNote
            )
            PopopxOnboardingHairline()
            featureRow(
                systemImage: "eye.slash.fill",
                tint: .danger,
                title: PopopxOnboardingCopy.shieldTitle,
                note: PopopxOnboardingCopy.shieldNote
            )
        }
    }

    private func featureRow(systemImage: String, tint: PopopxIconTint, title: String, note: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            PopopxOnboardingIconBadge(systemName: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 操作

    private var actions: some View {
        VStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
            PopopxButton(
                PopopxOnboardingCopy.createIdentity,
                systemImage: "person.crop.circle.badge.plus"
            ) {
                createProfileNavLinkActive = true
            }
            PopopxButton(
                PopopxOnboardingCopy.restoreBackup,
                systemImage: "tray.and.arrow.down.fill",
                role: .ghost
            ) {
                openRestoreEntry()
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.space2XS)
        .navigationDestination(isPresented: $createProfileNavLinkActive) {
            CreateFirstProfile()
                .modifier(ThemedBackground())
        }
    }

    /// 备份导入入口：只把 `migrationState` 置为「粘贴或扫码」，
    /// 页面顶部的迁移 sheet 绑定会立刻把它呈现出来（与原版同一条链路）。
    private func openRestoreEntry() {
        if m.migrationState == nil {
            m.migrationState = .pasteOrScanLink
        }
    }

    private func startHalo() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: Self.haloDuration).repeatForever(autoreverses: true)) {
            haloBreathing = true
        }
    }
}

let textSpace = Text(verbatim: " ")

let textNewLine = Text(verbatim: "\n")

struct POPOPXInfo_Previews: PreviewProvider {
    static var previews: some View {
        POPOPXInfo(onboarding: true)
        POPOPXInfo(onboarding: false)
    }
}
