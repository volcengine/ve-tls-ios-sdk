# SwiftExample — VolcengineTLSProducer 示例 App

最小 iOS App 示例，演示 `VolcengineTLSProducer` 的公开 API：
点击按钮 → `Producer.open` → `add(.immediate)` →
在界面上显示 `SendResult` 状态。

> **Development Preview**：`Producer.open` 当前接入 Real C Core。替换占位
> destination/credentials 后会发起真实 HTTPS 请求；请只在授权测试项目中运行。
> 本示例本身不是 BOE、真机或服务端送达证据。

## 环境

- 已验证：Xcode 26.6 / Swift 6.3.3
- 待验证：Xcode 14.3.1 / Swift 5.8
- iOS 13.0+ 模拟器或真机

## 方式一：直接打开自带工程（推荐先试）

```bash
cd Producer/Examples/SwiftExample
open SwiftExample.xcodeproj
```

工程已通过 **local Swift package** 依赖引用仓库根的 `Package.swift`
（`XCLocalSwiftPackageReference` 相对路径 `../../../`）。Xcode 打开后会自动
解析包并编译 `VolcengineTLSProducer`。选择模拟器，直接 Run。

> **pbxproj 兼容性风险**：`project.pbxproj` 为手写最小工程（objectVersion 56，
> Xcode 14 兼容）。如果你的 Xcode 版本打开时报错或无法解析包依赖，请改用
> 方式二手动新建工程——源文件（`SwiftExample/*.swift`、`Info.plist`）可直接复用。

## 方式二：在 Xcode 14.3.1 中新建工程并拖入源文件

1. **File → New → Project…**，选 **iOS → App**：
   - Interface：Storyboard 或 SwiftUI 均可（本示例代码不依赖 storyboard，
     使用代码构建 UI 与 Scene 生命周期）。
   - Language：**Swift**
   - 如选择 SwiftUI，删除模板生成的 `@main` App 结构体与 `ContentView`，
     改用本目录的 `AppDelegate.swift` / `SceneDelegate.swift`（需要在
     Target 的 Info 中配置 Scene 生命周期，见 `Info.plist`）。
2. 将 `SwiftExample/` 下的 `AppDelegate.swift`、`SceneDelegate.swift`、
   `ViewController.swift` 拖入工程（勾选 *Copy items if needed* 或保持引用均可）。
3. 用本目录的 `Info.plist` 替换或合并工程生成的 Info.plist（关键是
   `UIApplicationSceneManifest` 指向 `$(PRODUCT_MODULE_NAME).SceneDelegate`）。
4. 加入 SDK 依赖（二选一）：

   **SwiftPM（local package）**：
   - **File → Add Package Dependencies… → Add Local…**
   - 选择本仓库根目录（包含 `Package.swift` 的目录）。
   - 将 `VolcengineTLSProducer` 产品加入 App target。

   **CocoaPods（本地 lint/consumer 已验证；远端 tag 尚未发布）**：在 `Podfile` 中
   ```ruby
   platform :ios, '13.0'
   use_frameworks!

   target 'SwiftExample' do
     pod 'VolcengineTLSProducer', :path => '/path/to/ve-tls-ios-sdk'
   end
   ```
   然后 `pod install`，用 `.xcworkspace` 打开。

5. 编辑 `ViewController.swift` 顶部的占位配置：
   ```swift
   private let endpoint = "https://tls-cn-beijing.volces.com"
   private let region = "cn-beijing"
   private let projectID = "your-project-id"
   private let topicID = "your-topic-id"
   private let credentials = Credentials(
       accessKeyID: "your-access-key-id",
       accessKeySecret: "your-access-key-secret")
   ```
6. 仅在已授权的测试 project/topic 上 Run。点击 **Add Log** 后，界面显示
   实际 `SendResult`（可能成功或失败）。

## 关于 ATS

TLS endpoint 是 HTTPS，因此 `Info.plist` **不需要** `NSAppTransportSecurity`
例外（未使用 `NSAllowsArbitraryLoads`）。系统默认 TLS 校验生效，SDK 不提供
trust-all 开关。

## 代码说明

| 文件 | 作用 |
|---|---|
| `AppDelegate.swift` | `@main` 入口，返回默认 Scene 配置 |
| `SceneDelegate.swift` | iOS 13 scene 生命周期，安装 `ViewController` |
| `ViewController.swift` | 一个按钮：懒加载 open producer → `add(.immediate)` → 主线程显示 `SendResult` |
| `Info.plist` | Scene 清单；无 ATS 例外 |

## 证据边界

SDK package 与 public consumer 路径已在模拟器编译/测试；本手写示例工程尚未
作为 BOE 或真机证据执行。行为与发布边界以 `Producer/README.md` 和最新验收
报告为准。
