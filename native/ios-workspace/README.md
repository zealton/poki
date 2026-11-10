# Poki Workspace (experimental)

设备内的 OpenRouter Agent + LiveContainer 独立客体窗口。这个目标和原来的 Poki 全屏 XCTest 路径分开：它不依赖 Mac 上的命令循环，也不会向系统前台注入触摸或键盘事件。

**构建脚本支持 arm64 iOS Simulator 包和未签名 iPhone IPA（Xcode 26.2）。真机签名、长时间后台调度、PiP 和第三方 App 兼容性尚需真机验收；不要把模拟器结果当作已经可交付的真机产品。**

## 运行

在仓库根目录：

```sh
sh native/ios-workspace/scripts/test-policy.sh
python3 native/ios-workspace/scripts/build.py --device YOUR_BOOTED_SIMULATOR_UUID
xcrun simctl launch YOUR_BOOTED_SIMULATOR_UUID app.zealton.poki.workspace
```

首次构建下载固定版本的 LiveContainer、litehook、OpenSSL。构建日志和 Simulator ZIP 位于 `native/ios-workspace/.build/`。API key 不作为构建参数，也不写进安装包。

在 App 的密钥栏填写自己的 OpenRouter key，点“保存密钥”。修改目标任务，选容器内的 App，点“开始”。默认便宜的视觉模型 `deepseek/deepseek-v4.1-flash-1017`；模型 ID 可编辑，只允许 DeepSeek 命名空间，网络目标固定为 OpenRouter HTTPS API。模型可用性、价格和账户额度以 OpenRouter 实际返回为准。

主界面的下半部分是客体的真实远程场景。支持 PiP 的设备上可以点“悬浮预览”；模拟器若显示 `PiP unavailable`，不会伪造一个悬浮窗口。人直接触碰客体会暂停 Agent；触碰其他 App 不走客体事件通道。

## 实现

- Host：设置、Keychain、任务授权、真实远程窗口、暂停/停止和单步批准。
- Worker：独立 LiveProcess 内的可信工作进程，持有本轮内存密钥，直接请求 OpenRouter，观察→模型→校验→动作→再观察。请求超时 45 秒，默认 24 步、10 分钟，需要人继续才增加预算，最多 60 步。
- GuestBridge：只注入被选中的客体，采集其 UIWindow/CALayer 的真实像素和 UIKit 控件信息。普通按钮投递原有 UIControl 事件，文本直接修改非安全输入框，滚动仅操作本进程 UIScrollView。
- XPC：匿名端点、实际 peer PID 校验、随机 run ID、当前观察 ID 及控件标签/位置校验。停止撤销客体权限，迟到的模型回复用 epoch 丢弃。宿主断开后停止，崩溃不自动恢复任务。
- 密钥通过 Host→Worker XPC 传入，不放进会被运行时打印的 bootstrap 字典，不交给 GuestBridge。Host 使用单独的 owner Keychain access group。Keychain 失败时界面明确提示仅在内存中使用，退出后需重新输入，不回退到明文持久化。可用“清除密钥”停止任务并删除本机保存的 key。

## 范围和限制

这不是完整 iOS 虚拟机，也不是后台控制任意系统已安装 App 的通用方案。需要把有权使用、可被 LiveContainer 加载且可注入的客体放入容器；App Store 加密可执行文件不能直接导入。原 LiveContainer 管理界面保留在“导入 / 管理”。导入后必须确认签名、容器、TweakLoader 和多任务兼容性；仅支持能观察/操作的 UIKit 控件，不能承诺小红书等具体第三方 App 已通过验证。

CALayer 采集不保证包含 Metal、视频、受保护内容或某些 WebKit 合成层。自绘手势、系统弹窗、授权、登录和验证码可能需要人工处理；不使用全局 HID 作为降级路径。客体在 Agent 持有操作权限时请求常见的键盘焦点、切换窗口或打开其他 App 会被阻止或暂停；这不是对所有私有 API 的完备拦截。

LiveContainer 使用私有 API 和共享签名/运行时权限，**进程分离不是对恶意客体的安全沙箱**。只导入可信 App。模型会收到选中客体的截图、控件文字、任务和最近动作；不要在敏感页面运行。支付、发送、删除等标签触发批准只是启发式保护，不能替代应用权限或人工审查。

## 自动验证

`Tests/policy.m` 检查不合法模型输出、越界动作、模型 ID 和敏感操作标签。`Tests/UI/ConcurrencyTests.m` 提供前台 TypingPad 并发输入的 XCTest 场景；测试框架只负责用户输入，不负责 Agent 的模型循环。

用 `--workspace-test` 启动时，仅对内置 PokiFixture 开启测试诊断：Worker 自己的 Documents 中保存 `fixture-run.json` 和 `fixture-guest.jpg`，客体保存 `fixture.json`，TypingPad 保存 `evidence.json`。不保存 key；普通任务默认不持久化截图和动作。公开证据前仍需检查文本和图片。

## 真机验收清单

需要合法签名的 Host / LiveProcess、设备可用的 LiveContainer JIT-less 或 JIT 配置、签名后的 Worker / Bridge / 客体，随后单独验证 Keychain、XPC 身份、输入焦点、PiP、系统后台回收及停止行为。使用下面的命令生成设备架构的未签名包（不能直接安装）：

```sh
python3 native/ios-workspace/scripts/build.py --platform device --work /private/tmp/poki-workspace-device
```

生成 `PokiWorkspace-unsigned.ipa`。通过你自己的合法签名/侧载工具签名，保留 LiveProcess 扩展，按 LiveContainer 要求完成设备配置。在“导入 / 管理”的设置里配置自己的容器签名证书。Host 会先为 Bridge 和客体转换/签名，再创建工作进程；证书缺失时停在配置界面。这里没有连接可验收的真机，因此未签名包的编译成功也不代表签名、安装和运行已验证。不要把 Simulator ZIP 重命名为 IPA。

## 许可

本目标代码 AGPL-3.0-only。运行时基于 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的 `9d6ea09b05afa2c8fc537c372795a294db631311`，保留其原始版权和 AGPL 许可；依赖由固定提交下载。`scripts/runtime.patch` 是对该版本的可审查修改。


## 无明文文件的 Simulator 测试密钥输入

Debug Simulator 的显式测试启动可使用 `--workspace-test --workspace-key-fifo PATH`。PATH 必须是当前 UID 所有、权限 0600 的 FIFO；只读一次，不接受普通文件。建议把 FIFO 放在系统临时目录，避免 macOS 对 Documents 的访问限制。不要把 key 放进命令行、环境变量、XCTest `typeText` 参数或结果包。普通安装不打开这个通道，设备构建完全不编译该入口。

`--workspace-test-count 10 --workspace-test-focus` 将内置任务延长到 10 次点击，并使普通按钮业务回调尝试获取键盘焦点；`--workspace-run-fixture` 在收到测试 key 且 IPC 就绪后开始内置任务。它们只用于自动验收，正常运行使用界面按钮。


完整并发输入用例：先在 Host 中配置 key（Keychain 或本轮内存），通过 Xcode 为 `PokiWorkspaceHelpers` 执行 Build for Testing，再运行 `WorkspaceTests/WorkspaceConcurrencyTests/testAutonomousGuestWhileTyping`。测试要求内置目标计数为 10，并开启 `--workspace-test-focus`。`scripts/collect-fixture.py SIMULATOR_UUID OUTPUT_DIR` 交叉核对模型完成状态、真实业务回调、输入、生命周期和像素；使用普通 Mac 键盘通道时加 `--native-input`，单独计入 iOS 默认的句首自动大写。
