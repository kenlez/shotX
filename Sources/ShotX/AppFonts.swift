import AppKit
import CoreText

enum AppFonts {
    private static let postScriptName = "AlimamaFangYuanTiVF-Thin"
    private static let fileName = "AlimamaFangYuanTiVF-Bold-sub"
    private static var registered = false

    /// 字体所在 bundle。加载路径与既有资产代码一致：优先取打包后的
    /// `ShotX.app/Contents/Resources/ShotX_ShotX.bundle`，兜底 SwiftPM 的 `Bundle.module`。
    static var resourceBundle: Bundle {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ShotX_ShotX.bundle")
        return packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
    }

    /// 应用启动时注册内嵌字体（幂等）。
    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = resourceBundle.url(forResource: fileName, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// 截图文字标注工具的唯一字体工厂。Alimama 仅覆盖 109 字形，缺失字形由 AppKit
    /// 逐字形级联回退；字体未注册时兜底系统字体（功能不回退）。
    static func annotationFont(size: CGFloat) -> NSFont {
        NSFont(name: postScriptName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
}
