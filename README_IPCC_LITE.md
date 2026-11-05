# AirIPCC Lite

一个只做「锁定 IPCC」的侧载工具，基于 [AirBeep 2.5.2](https://github.com/) 源码改造。

保留 AirBeep 原有的通话提示音静音功能，新增第二个页签「锁定 IPCC」：把内置的运营商配置写进
`/var/mobile/Library/Carrier Bundles/iPhone/`，然后让设备重启，使 CommCenter 加载国内运营商。

**没有激活码，没有联网校验，没有任何服务端依赖。**

## 它怎么工作

1. 解包内置的 `O2_Germany.ipcc` —— 这是一份**真正被 Apple 签名过的运营商 bundle**，`signatures/` 与所有 `*.der.pri` 保持字节不变。
2. 用内置的 `46000 / 46001 / 46011 / 46015.plist` 整份替换 `carrier.plist`。签名只覆盖 `*.der.pri`，不覆盖 `carrier.plist`，所以替换后签名依旧有效。
3. 改写 bundle 身份：`CFBundleIdentifier`、`CFBundleName`、`CFBundleExecutable`，并把 `CFBundleVersion` 提到 `9999`，让 CommCenter 优先选这份而不是系统自带版本。
4. 通过 Airlift 的 `al_exploit_write_dir` 把它推进设备的 `Carrier Bundles/iPhone/<bundle>`：先写根目录的平铺文件，再写 `signatures/` 子目录。
5. 调 `al_device_respring` 让设备重启。

整个写入走 AirTraffic（Apple Books 的同步通道），以 `mobile` 身份完成，不需要越狱。

## 构建

1. Fork 或新建仓库，把本目录整体推上去。
2. 仓库 Settings → Actions → General → Workflow permissions 选 **Read and write permissions**。
3. 打一个 tag（如 `v1.0`）或手动跑 `Release unsigned IPA` workflow。
4. 运行器是 `xcode-27`，会自动 clone `mak5er/AirCard-iOS`（commit `40640c4`）、叠加 `scripts/airlift-read-file.patch`、重建 `AirliftFFI.xcframework`，再 archive 出未签名 IPA。
5. 产物：`airipcc-lite-v1.0-unsigned.ipa`。用 TrollStore 安装，或 `ldid -S` 后侧载。

本地构建同理：

```bash
bash scripts/build-airlift-xcframework.sh
xcodebuild archive -project airbeep.xcodeproj -scheme airbeep \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath /tmp/lite.xcarchive \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## 使用

1. 打开「配对」页完成自配对（iOS 27 及以上可直接在 设置 › 隐私与安全性 › 开发者模式 › 与 AirBeep 配对；更低版本需从电脑导入配对文件）。
2. 连好 LocalDevVPN。
3. 到「锁定 IPCC」页选运营商 → 执行锁定。
4. 设备重启后，去 设置 › 通用 › 关于本机 › 运营商 确认版本。

## 已知限制（务必先看）

**Airlift 的版本差异是这套代码最大的不确定项。** AirBeep 用的 `40640c4` 只导出了
`al_exploit_write_dir` / `al_exploit_read_file` / `al_find_app_container` / `al_device_respring`，
**没有** `al_exploit_inject_folder`、`al_exploit_clear_dir`、`al_exploit_write_symlinks`——虽然
`Vendor/AirCard/.../airlift.h` 里能读到 `inject_folder` 的声明，但 `.a` 里没有对应符号，调用会 `dlsym` 失败。

因此本工程用两次 `al_exploit_write_dir` 代替 `inject_folder`。**这里有一个未验证的假设：该版本的
`write_dir` 会在设备上创建不存在的目标目录。** 如果首次运行报
`al_exploit_write_dir 返回 1（目标 …/CMCC_cn.bundle）`，说明它不会建目录，需要按下节升级 Rust 层。

另外两点同样需要在真机上验证：

- `bundleName` 与 `bundleIdentifier` 的映射（`CMCC_cn.bundle` / `com.apple.Carrier_CMCC_cn` 等）是公开命名惯例，不同 iOS 版本可能有出入。
- 把 `CFBundleVersion` 提到 `9999` 是让 Overlay 优先被采用的手段，若 CommCenter 额外比对 `version.plist` 的 `SourceVersion`，可能仍会回落到系统 bundle。

## 升级 Rust 层（可选）

如果想要 AirIPCC 那套完整能力（符号链接、清空目录、整目录注入），需要 fork `AirCard-iOS` 并在
`rust-core/src/exploit.rs` 里补三个 FFI：

```rust
al_exploit_inject_folder   // 整目录一次性搬运（保留层级）
al_exploit_clear_dir       // 清空目标目录
al_exploit_write_symlinks  // 在 Overlay 里建指向系统 bundle 的相对符号链接
```

Airlift 内部的 `build_archive` / `build_books_plist` / `posix_rel` / `exploit_write_single_file`
已经具备所需的 ATC 消息拼装能力，符号链接版可参照 AirIPCC 二进制里的约束
（`both link_path and target must be absolute paths`、`link must be at least one level below Carrier Bundles`）。

## 数据来源

`airbeep/IPCCData/` 下的 `O2_Germany.ipcc` 与 `460xx.plist` 取自公开分发的 AirIPCC 1.0 安装包。
`O2_Germany.ipcc` 是 Apple 签名的运营商配置，版权归 Apple 与 Telefónica 所有，仅作技术验证使用。

## 与 AirIPCC 的关系

这不是 AirIPCC 的源码重建。AirIPCC 只发布了编译产物，没有公开源码；本工程是按二进制里可观察到的
行为（路径、Overlay 策略、IPCC 外壳替换、respring）重新实现的**功能等价版本**，界面、状态机、
错误处理都是新写的，因此行为细节不会与 AirIPCC 完全一致。
