# 美敦力 712 / 712E → Loop (MinimedKit) 移植包

这是从 AndroidAPS 3.2.2.2（包 `info.nightscout.androidaps`）里拆出来的 712 协议分支，改写成 Swift，补进 Loop 的 `MinimedKit`。

只加 512/712 家族，不动现有 722/723 及以上的逻辑。

**已在 GitHub Actions 的 macOS 上真实编译通过**：Xcode 16.4（16F6），`MinimedKit`、`MinimedKitUI`、`MinimedKitPlugin` 的模拟器 Debug（arm64）和真机 Release（arm64）全部 `BUILD SUCCEEDED`；框架符号表里能查到 `getSettings712()` / `getDeliveryLimits()` / `getCurrentPumpStatus712()`。验证仓库：`https://github.com/670489857/minimed712-ci`，构建记录：`https://github.com/670489857/minimed712-ci/actions/runs/45134006525`。

## 0. 三步上手

1. **一次到位**：在 MinimedKit 仓库根目录执行

   ```bash
   git apply Patches/all-in-one-full.patch
   ```

   这个补丁把 5 处源码改动 + 2 个新 Swift 文件 + 1 处 `MinimedKit.xcodeproj` target membership 全部打进去（共 8 个文件），不需要手动拖文件，也不会再出现“新文件没进 target”的链接错误。

2. **或者手动**：把 `Sources/` 下两个 `.swift` 拖进 **MinimedKit target**（不要放 App target），再 `git apply Patches/all-in-one.patch`，最后套用 `Patches/06-XcodeProject.patch`（或手动勾 target membership）。

3. 编译，配对时 Region 选 **WW（868MHz）**，进系统后先把 `getSettings712()` 的 `maxBasal/maxBolus` 和泵屏幕对一遍。

> 这是源码补丁包，不含编好的 IPA。代码已在 macOS/Xcode 16.4 真实编译验证（见第 10 节），但没有 712 实机抓包，也没有在完整的 Loop App 里跑过闭环。报错发我，按报错修。

---

## 1. 这个包解决了什么

Loop 的 `MinimedKit` 里其实**已经有** `PumpModel.model712`，储药器也按 300U 算了，历史解析、大剂量、TBR、基础率读写都支持 512/712。真正缺的是三块：

| 缺口 | 现状 | 本包的处理 |
|---|---|---|
| 设置读取 | `getSettings()` 固定发 `0xC0`，只认 65 字节的 522+ 格式 | 新增 `0x91`（512/712 Configuration）和 22 字节起头的变长解析 |
| 运行状态 | `getPumpStatus()` 固定发 `0xCE`，AAPS 里这条命令只对 515+ 开放 | 新增 `getCurrentPumpStatus712()`：0x72 电量 + 0x73 余量 + 历史事件推暂停 |
| 型号选择 | 上游 Loop 是自动识别，没有手选列表；有些 fork 写死了 722 | 提供型号数组，UI 里加 `.model712` 即可 |

---

## 2. 文件放哪

把 `Sources/` 里的两个文件加进 **MinimedKit target**（不是 Loop App target）：

```
MinimedKit/
├── Messages/
│   └── ReadSettings512CarelinkMessageBody.swift   ← 新增
├── PumpManager/
│   └── Minimed712Support.swift                    ← 新增
```

> 必须放进 MinimedKit target，因为这些扩展要用到 `PumpOpsSession` 的 internal 成员。加到 App target 会编译不过。

`Patches/06-XcodeProject.patch` 就是替你完成“Add to target”：把两个新文件加进 `MinimedKit` target 的 Sources 阶段。`all-in-one-full.patch` 已包含它；如果你们的 fork 改过 `project.pbxproj` 导致补丁冲突，就在 Xcode 里手动把两个文件拖进 `MinimedKit` 组并勾选 target membership（这一步不做，编译会报 `has no member 'is512or712Family'`）。

测试文件 `Tests/ReadSettings512CarelinkMessageBodyTests.swift` 可选，加到 `MinimedKitTests`。

---

## 3. 六处补丁（5 处代码 + 1 处工程文件，必须做）

`Patches/` 里是对着上游 `LoopKit/MinimedKit` 生成的 diff，可以直接：

```bash
cd <你的 MinimedKit fork>
git apply --check Patches/all-in-one-full.patch
git apply Patches/all-in-one-full.patch
```

也可以按 01→06 顺序单独打（已验证六个可以顺序 apply）。如果 fork 已经改过这几处、patch 打不上，就按下面手动改。

### 3.1 `MinimedKit/Messages/MessageType.swift`

加命令码：

```swift
case getPumpModel                 = 0x8d
case readSettings512              = 0x91   // ← 加这行
case readProfileSTD512            = 0x92
```

加响应解析映射：

```swift
case .readSettings:
    return ReadSettingsCarelinkMessageBody.self
case .readSettings512:                     // ← 加这两行
    return ReadSettings512CarelinkMessageBody.self
```

不加这个，泵回的 0x91 会被当成 `UnknownMessageBody`，`getSettings712()` 永远拿不到数据。

### 3.2 `MinimedKit/PumpManager/PumpOpsSession.swift`

两处可见性（让新文件里的 extension 能发命令）：

```swift
// 原来：private let messageSender: PumpMessageSender
let messageSender: PumpMessageSender

// 原来：private func wakeup(...)
func wakeup(_ duration: TimeInterval = TimeInterval(minutes: 1)) throws {
```

状态读取分流：

```swift
public func getCurrentPumpStatus() throws -> PumpStatus {
    let pumpModel = try getPumpModel()

    if pumpModel.is512or712Family {              // ← 加这 4 行
        return try getCurrentPumpStatus712()
    }

    let battResp = try getBatteryStatus()
```

大剂量前检查分流：

```swift
// 原来：let status = try getPumpStatus()
let status = try getActiveState(for: pumpModel)
```

`getActiveState` 返回同样的 `(suspended, bolusing)`，后面的 `status.bolusing` / `status.suspended` 不用改。

### 3.3 `MinimedKit/PumpManager/MinimedPumpManager.swift`

`syncDeliveryLimits()` 做两件事：

1. 回读限额改用型号感知的 `getDeliveryLimits()`（712 走 0x91，不再用 0xC0）；
2. 写上限（0x6E / 0x41）失败时，512/712 不中断，继续按泵里的实际值回读并回报。

```swift
// 原来：let settings = try session.getSettings()
let settings = try session.getDeliveryLimits()
```

不改回读，712 上一改限额就会因为 0xC0 被 NAK 而失败；不改回退，有些 712 会在写上限那一步直接让 setup 失败。

### 3.4 短帧补零（强烈建议，`04-ShortFramePadding.patch`）

Loop 的模型、时间、电量、余量这几个解析器都写死了 `rxData.count == 65`。512/712 这类老泵有可能回的是短帧（AAPS 里 `CarelinkLongMessageBody` 就是专门把短帧补到 65 再解析的）。

补丁做两件事：

- `MessageType` 增加 `fixedResponseLength`，只对 `0x8D / 0x70 / 0x72 / 0x73 / 0x98 / 0x91 / 0x74 / 0x76` 返回 65；
- `PumpMessage.init(rxData:)` 在解析前把不足 65 的 body 补零。

对 722/723 没影响（本来就是 65）。**症状对照**：如果 setup 一开始就报 `noResponse` / `unexpectedResponse`、连型号都读不出来，多半就是短帧，先把这条补丁打上再试。

### 3.5 setup 写上限失败不中断（`05-SetupLimitFallback.patch`）

`MinimedPumpIDSetupViewController.setupPump()` 在配对最后会写最大大剂量/最大基础率。712 的 0x41 / 0x6E 命令口径和 x22 系列不完全一样，写不进去时对 512/712 只记日志、继续往下走；泵上的上限保持你在面板里手动设的值。其他型号行为不变。

**这意味着**：712 首次配对前，先在泵面板上把“最大大剂量 / 最大基础率”设成你要的值，否则 Loop 里允许的剂量可能被泵拒。

### 3.6 工程文件 target membership（`06-XcodeProject.patch`）

MinimedKit 用的是 `.xcodeproj` 而不是 SwiftPM，新增 `.swift` 不会自动进 target。这个补丁在 `MinimedKit.xcodeproj/project.pbxproj` 里给两个新文件加 `PBXBuildFile`、`PBXFileReference`、组内引用和 Sources 阶段条目。

如果你们的 fork 工程文件结构已经变化、补丁打不上：在 Xcode 里把两个文件拖进 `MinimedKit` 组，File Inspector 的 Target Membership 只勾 `MinimedKit`。漏掉这一步的典型报错是：

```text
error: value of type 'PumpModel' has no member 'is512or712Family'
```

---

## 4. 如果你们的 UI 只有 722、没有 712 选项

上游 Loop 是用 `session.getPumpModel()` 自动识别型号的，没有手选列表。你们的 fork 如果有下拉框，按这个加：

```swift
// 直接拿来填 Picker
PumpModel.minimedSelectableModels   // 已包含 .model712

// 或者在原列表里加一项
[.model722, .model712, ...]
```

如果 setup 或 state 初始化里写死了 `pumpModel: .model722`，改成连接后读到的：

```swift
let model = try session.getPumpModel()   // 712E 也会报 "712"
```

显示名可以用 `PumpModel.minimedDisplayName`（712 显示为 “712 / 712E”）。

**区域一定要选对**：712E/国内版是 Worldwide 868MHz，美加版才是 916MHz。setup 页面里 `RegionCode` 选 `WW`。选错频率的表现是“能连上 RileyLink，但永远 tune 不到泵”。

---

## 5. 建议的验证顺序

不要跳步，尤其是第 3 步。

1. **编译**：先只加文件 + 补丁，确认 `MinimedKit` target 能过。
2. **识别**：setup 里 `getPumpModel()` 返回 `712`，firmware 能读出来，region = WW。
3. **设置对照（关键）**：调 `getSettings712()`，把 `maxBasal` / `maxBolus` 和泵屏幕上的“最大基础率 / 最大大剂量”逐位对一遍。这两个值错了后面所有限幅都是错的。
4. **状态**：`getCurrentPumpStatus712()` 看电量、余量、泵时间；712 的储药器应显示 300U。
5. **历史**：`getHistoryEvents(since:)` 能正常解析最近事件，CRC 不报错。
6. **小剂量**：0.1U 大剂量，泵上确认实际输注量。
7. **TBR**：30 分钟、0.05 步进的临时基础率，确认泵上生效并能取消。
8. **暂停/恢复**：在泵上直接暂停，等一次状态刷新，确认 `getRunState712()` 能识别。
9. **闭环**：先观察模式跑够时间，再开闭环。

---

## 6. 已知限制（务必看）

- **0xCE 在 712 上不可用**。AAPS 把这条命令限定在 515+，所以 712 的 `suspended` 是从历史里的暂停/恢复事件推出来的；`bolusing` 只能当辅助参考——普通大剂量历史是“事后追加”，输注中查不到。真正的重叠保护靠 Loop 的 `unfinalizedBolus` 和泵本身对第二条大剂量命令的 `commandRefused`。
- **状态刷新会变慢**：暂停/大剂量状态要回扫最近 12 小时历史，通常 2–6 页，多 2–6 秒。Loop 原本 5 分钟一次，可以接受；别把它塞进 30 秒轮询。
- **超长暂停**：如果泵被暂停超过 12 小时且期间没有任何其他事件，这次回扫看不到那条 Suspend，会误报“未暂停”。Loop 自己下发的暂停有 state 记录，不受影响；只有“在泵上手动暂停并放了一夜以上”才会碰到。
- **712 没有 CGM**：闭环的血糖必须来自外部 CGM。
- **onboarding 的速率表**仍是按 522 的 0.025 步进生成的。712 只能 0.05 步进，如果初始化时填了 0.325 这种值，下发到泵会被取整，Loop 内部记录和泵实际值可能差一档。可选修法：把 `MinimedPumpManager.onboardingSupportedBasalRates` 改成 `PumpModel.model712.supportedBasalRates`（代价是 523 用户也只剩 0.05 精度）。
- **CI 只验证编译，不验证协议**：GitHub 的 macOS runner 证明 `MinimedKit` / `MinimedKitUI` 能在 Xcode 16.4 下编译、链接，符号存在；但 runner 没有 RileyLink 和 712 泵，0x91 解析、短帧、暂停推断是否正确，仍要靠台架和实机。
- **CI 验证的是上游 MinimedKit HEAD**：`LoopKit/MinimedKit` 提交 `cce1a49`（2026-11-10）+ `LoopKit` / `RileyLinkKit` 最新默认分支。你们 fork 如果改过 `PumpOpsSession` / `MinimedPumpManager` 的签名，可能还要按报错对齐。
- **医疗安全**：712 是二十多年前的泵，马达、电池、历史页 CRC 都可能老化。先在台架上把 3–8 步走完，别拿它直接跑闭环给药。这个包只做协议移植，不做临床验证。

---

## 7. 关键参数备忘

| 项 | 712 / 712E |
|---|---|
| 命令：读设置 | `0x91`（不是 0xC0） |
| 命令：读状态 | `0xCE` 不支持，用 `0x72` + `0x73` + 历史 |
| 大剂量刻度 | 10 刻度/U（0.1U） |
| 基础率下发 | 40 刻度/(U/h)，Loop 侧按 0.05 步进取值 |
| 储药器 | 300U |
| 频率 | Worldwide 868.25–868.65MHz（712E）/ NA 916.45–916.80MHz |
| 固件限制 | 任意版本（AAPS 官方文档口径） |
| 最大基础率 | 35 U/h（设置块里按 40 刻度/U 存，解析要除以 40） |
| 最大大剂量 | 25 U |

---

## 8. 完整性清单

**这个包里有的：**

- `Sources/Minimed712Support.swift` — 型号判定、0x91 读设置、0xCE 替代状态、限额回读（完整源码）
- `Sources/ReadSettings512CarelinkMessageBody.swift` — 0x91 响应解析（完整源码）
- 5 个代码补丁，覆盖 `MessageType.swift`、`PumpMessage.swift`、`PumpOpsSession.swift`、`MinimedPumpManager.swift`、`MinimedPumpIDSetupViewController.swift`
- 1 个工程文件补丁 `06-XcodeProject.patch`，把两个新文件加进 `MinimedKit` target
- `all-in-one-full.patch`：上面 6 个补丁合并，一次 `git apply` 到位（含 2 个新文件，共 8 个文件）
- 可选单元测试
- `CI/build.yml`：GitHub Actions 编译脚本（LoopKit + RileyLinkKit + MinimedKit 模拟器/真机两套构建）
- 真实编译记录：Xcode 16.4，MinimedKit / MinimedKitUI / MinimedKitPlugin 的模拟器 Debug arm64 + 真机 Release arm64 全部通过

**这个包里没有的：**

- 编译好的 IPA / .app（需要你自己的 Xcode + 签名）
- 完整 Loop App 的构建（本包只验证了 `MinimedKit` / `MinimedKitUI` / `MinimedKitPlugin` 三个 target 及其依赖）
- 712 实机抓包和闭环验证

---

## 9. 文件清单

```
Sources/
  ReadSettings512CarelinkMessageBody.swift   0x91 解析（22 字节起，容忍变长响应）
  Minimed712Support.swift                    型号判定、设置读取、状态替代、限额回读
Patches/
  01-MessageType.patch
  02-PumpOpsSession.patch
  03-DeliveryLimits.patch
  04-ShortFramePadding.patch
  05-SetupLimitFallback.patch
  06-XcodeProject.patch（把两个新文件加进 MinimedKit target）
  all-in-one.patch（五个代码补丁合并，不含新文件）
  all-in-one-full.patch（六个补丁 + 两个新文件，一次到位，共 8 个文件）
Tests/
  ReadSettings512CarelinkMessageBodyTests.swift
CI/
  build.yml（GitHub Actions：模拟器 Debug + 真机 Release）
```

---

## 10. 编译验证记录（2026-11-23）

不是“看着像能编译”，是真的在 macOS 上跑了 `xcodebuild`。

| 项 | 结果 |
|---|---|
| Runner | GitHub Actions `macos-15`（arm64） |
| Xcode | 16.4，Build 16F6 |
| 依赖 | `LoopKit` 最新默认分支；`RileyLinkKit` 最新默认分支；`MinimedKit` 提交 `cce1a49` |
| 模拟器 | `MinimedKit` + `MinimedKitUI` + `MinimedKitPlugin`，Debug，`iphonesimulator arm64`，`BUILD SUCCEEDED` |
| 真机 | `MinimedKit` + `MinimedKitUI` + `MinimedKitPlugin`，Release，`iphoneos arm64`，`BUILD SUCCEEDED` |
| 目标文件 | `Minimed712Support.o`、`ReadSettings512CarelinkMessageBody.o` 均生成 |
| 符号表 | `MinimedKit.PumpOpsSession.getSettings712()`、`getDeliveryLimits()`、`getCurrentPumpStatus712()` 均可 demangle 出 |
| 真机二进制 | `build-device/Release-iphoneos/MinimedKit.framework/MinimedKit`，2,068,376 字节 |
| 警告 | 只有 LoopKit / LoopKitUI 的既有弃用警告，本包新增代码无 error |

复现方式：把打好补丁的 `MinimedKit` 仓库推到 GitHub，Actions 选 `iOS build` 手动运行。注意 GitHub 的 macOS runner 会计费：公开仓库免费，私有仓库需要账户有可用额度（我这次私有仓库第一次就被计费拦了，临时改公开才跑起来）。

构建记录：`https://github.com/670489857/minimed712-ci/actions/runs/45134006525`（公开仓库，可直接看日志）。

> 说明：私有仓库第一次构建被 GitHub 的 macOS runner 计费拦下（`The job was not started because recent account payments have failed or your spending limit needs to be increased`），所以验证仓库当前是 **public**，用公开仓库的免费 macOS 额度跑完。仓库里只有 MinimedKit 源码和本包补丁，没有 token、没有账号信息。要改回 private 或删掉，跟我说。
