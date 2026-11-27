//
//  QRCode.swift
//  POPOPX
//
//  Created by Evgeny Poberezkin on 30/01/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//
// Spec: spec/client/navigation.md

import SwiftUI
import CoreImage.CIFilterBuiltins
import POPOPXChat
import PopopxMeshKit

struct MutableQRCode: View {
    @Binding var uri: String
    var small: Bool = false
    var withLogo: Bool = true
    var tintColor = UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1)

    var body: some View {
        QRCode(uri: uri, small: small, withLogo: withLogo, tintColor: tintColor)
            .id("popopx-qrcode-view-for-\(uri)")
    }
}

struct POPOPXCreatedLinkQRCode: View {
    let link: CreatedConnLink
    @Binding var short: Bool
    /// When set, the code encodes this instead of the link's own URI: the sealed `/i/v1/` form the
    /// screen prints as text right above it. A QR that disagrees with the text beside it is worse than
    /// either one alone.
    var encodedURI: String? = nil
    var onShare: (() -> Void)? = nil

    var body: some View {
        // A screen that passes no `encodedURI` still gets a share: this view is only ever handed
        // connection addresses, so the default is the sealed form of the selected link. `small` is
        // decided by the string actually encoded: the sealed code is longer than the address it
        // hides, so the compact, error-level-M rendering is wrong for it even when the user picked
        // the short link.
        let uri = encodedURI ?? PopopxInviteShareForm.make(from: link, short: short).display
        QRCode(uri: uri, small: uri.count < 200, onShare: onShare)
    }
}

/// The one form a screen should print, encode and share for a stored connection address: the sealed
/// `/i/v1/` code when the address can be sealed, unchanged when it already is one of those codes
/// (handing a share back to a formatter must not mint a different link), and the plain address when
/// the codec refuses it. Migration file links and relay addresses are not connection addresses and
/// must not be passed here — they are consumed in their plain form by other parsers.
func popopxSharedLink(_ uri: String) -> String {
    PopopxInviteShare.sharedLink(forURI: uri, seal: PopopxInviteSealCache.link(forURI:))
}

struct POPOPXLinkQRCode: View {
    let uri: String
    var withLogo: Bool = true
    var tintColor = UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1)
    var onShare: (() -> Void)? = nil

    var body: some View {
        QRCode(uri: popopxChatLink(uri), small: uri.count < 200, withLogo: withLogo, tintColor: tintColor, onShare: onShare)
    }
}

private let smallQRRatio: CGFloat = 0.63

extension EnvironmentValues {
    struct FixedQRCode: EnvironmentKey {
        static let defaultValue: UIImage? = nil
    }

    var fixedQRCode: UIImage? {
        get { self[FixedQRCode.self] }
        set { self[FixedQRCode.self] = newValue }
    }
}

struct QRCode: View {
    let uri: String
    var small: Bool = false
    var withLogo: Bool = true
    var tintColor = UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1)
    var onShare: (() -> Void)? = nil
    @Environment(\.fixedQRCode) private var fixedQRCode
    @State private var image: UIImage? = nil
    @State private var makeScreenshotFunc: () -> Void = {}
    @State private var width: CGFloat = .infinity

    var body: some View {
        ZStack {
            if let image = fixedQRCode ?? image {
                qrCodeImage(image).frame(width: width, height: width)
                GeometryReader { g in
                    let w = g.size.width * (small ? smallQRRatio : 1)
                    let l = w * (small ? 0.195 : 0.16)
                    let m = w * 0.005
                    ZStack {
                        if withLogo {
                            Image("icon-light")
                            .resizable()
                            .scaledToFit()
                            .frame(width: l, height: l)
                            .frame(width: l + m, height: l + m)
                            .background(.white)
                            .clipShape(Circle())
                        }
                    }
                    .onAppear {
                        width = w
                        makeScreenshotFunc = {
                            let size = CGSizeMake(1024 / UIScreen.main.scale, 1024 / UIScreen.main.scale)
                            showShareSheet(items: [makeScreenshot(g.frame(in: .local).origin, size)])
                            onShare?()
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
            } else {
                Color.clear.aspectRatio(small ? 1 / smallQRRatio : 1, contentMode: .fit)
            }
        }
        .onTapGesture(perform: makeScreenshotFunc)
        .task { if fixedQRCode == nil { image = await generateImage(uri, tintColor: tintColor, errorLevel: small ? "M" : "L") } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func qrCodeImage(_ image: UIImage) -> some View {
    Image(uiImage: image)
        .resizable()
        .interpolation(.none)
        .aspectRatio(1, contentMode: .fit)
        .textSelection(.enabled)
}

func generateImage(_ uri: String, tintColor: UIColor, errorLevel: String) async -> UIImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(uri.utf8)
    filter.correctionLevel = errorLevel
    if let outputImage = filter.outputImage,
       let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
        return UIImage(cgImage: cgImage).replaceColor(UIColor.black, tintColor)
    }
    return nil
}

extension View {
    func makeScreenshot(_ origin: CGPoint? = nil, _ targetSize: CGSize? = nil) -> UIImage {
        let controller = UIHostingController(rootView: self.edgesIgnoringSafeArea(.all))
        let targetSize = targetSize ?? controller.view.intrinsicContentSize
        let view = controller.view
        view?.bounds = CGRect(origin: origin ?? .zero, size: targetSize)
        view?.backgroundColor = .clear
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            view?.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}

struct QRCode_Previews: PreviewProvider {
    static var previews: some View {
        QRCode(uri: "https://smp1.popopx.im/a#preview-contact-key", small: true)
    }
}
