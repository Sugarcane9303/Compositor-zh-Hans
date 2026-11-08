import Foundation

/// 本地化显示支持。
///
/// `localizedDisplay` 把以英文原始值（`rawValue`）存储的枚举值转成当前语言的显示文本。
/// 枚举的 `rawValue` 多为持久化格式（`CodingKey`/存储键），不可更改，因此只在显示处转换：
///
///     Text(kind.localizedDisplay)
///     Label(mode.localizedDisplay, systemImage: "circle")
///
/// 查找 "Localizable" 表（`Localizable.xcstrings` 编译产物），找不到时返回原文。
extension String {
    /// 当前语言的显示文本；未收录时返回英文原文。
    var localizedDisplay: String {
        NSLocalizedString(self, comment: "")
    }
}

/// `String(localized:)` 的兼容封装：macOS 13 及以下不可用时走 `NSLocalizedString`。
/// 工程目标为 macOS 26，`String(localized:)` 总可用，此扩展仅为调用点统一风格。
extension String {
    /// 用插值字面量构造并本地化：`String(localizedInterpolated: "Layer \(number)")`。
    /// 键为插值全文按类型推断出的格式串（如 `"Layer %lld"`）。
    init(localizedInterpolated key: String, _ args: CVarArg...) {
        self.init(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
}
