# Edge HTTP Compat

[![Windows tests](https://github.com/Cq-12345/edge-http-compat/actions/workflows/test.yml/badge.svg)](https://github.com/Cq-12345/edge-http-compat/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**让仍需使用 HTTP 的网站与新版 Microsoft Edge 共存。** 使用微软正式支持的浏览器策略，提供只读诊断、关闭自动 HTTPS 升级、指定网站例外、备份和撤销。

[English](README.en.md) · [版本要求](#compatibility) · [快速使用](#quickstart) · [Beta / Dev / Canary](#channels) · [故障排查](#troubleshooting)

适合这样的情况：输入某个域名后 Edge 尝试访问 `https://`，该网站连接失败，而同一网站的 `http://` 可以正常打开。脚本处理的是**浏览器自动升级协议的配置**，不能修复网站服务器、DNS、代理或所有 HTTPS 错误。

## 先选合适的操作

| 需求 | 操作 | 最低 Edge 主版本 |
|---|---|---:|
| 看版本和本地策略，不修改 | `Status`，也是默认操作 | 不设置策略版本门槛 |
| 让 Edge 停止自动将 HTTP 升级为 HTTPS | `DisableUpgrade` | **136** |
| 只为一个或几个旧网站设置长期 HTTP 例外 | `AllowHttp` | **123** |
| 撤销本工具的一次修改 | `Restore` | 不依赖 Edge 是否仍安装 |

如果只有少数旧网站有问题，可选 `AllowHttp`，其他网站继续使用默认自动升级行为。确实需要全局关闭自动升级时，选 `DisableUpgrade`。两种操作都不会把已经明确使用 HTTPS 的链接统一改成 HTTP，也不会关闭证书校验。

**默认检测的是正式版 Edge（Stable），不是 Beta。默认运行只读，不会自动修改设置或请求管理员权限。**

<a id="compatibility"></a>

## 版本要求与验证范围

- 系统：Windows；脚本以 Windows 10 / 11 桌面环境为目标。
- 运行环境：Windows PowerShell **5.1** 或 PowerShell **7**，不需要安装第三方模块。
- 浏览器：Microsoft Edge 桌面版。政策支持的版本范围与脚本测试范围不同，见下表。
- macOS / Linux：此实现不支持；不要把 Windows 注册表命令照搬到这些系统。

| 机制 / 策略 | 微软文档中的 Windows 版本要求 | 本项目如何使用 |
|---|---:|---|
| `HttpsUpgradesEnabled` | ≥ 136 | `DisableUpgrade` 写入 DWORD `0` |
| `HttpAllowlist` | ≥ 123 | `AllowHttp` 追加规范化的主机名 |
| `HttpsOnlyMode` | ≥ 140 | 诊断时读取；**不修改** |
| `AutomaticHttpsDefault` | 旧策略，136 起弃用，139 计划移除 | **不写入、不作为旧版兜底** |

来源：[自动 HTTPS 升级](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpsUpgradesEnabled)、[HTTP 例外列表](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpAllowlist)、[HTTPS-Only 模式](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpsOnlyMode)、[136–139 版 HTTPS 策略迁移](https://learn.microsoft.com/en-us/microsoft-edge/web-platform/site-impacting-changes)。文档核对日期：2026-11-01。

### 已验证与尚未验证

- 本地自动化测试：Windows PowerShell **5.1.26100.9549**、PowerShell **7.6.5**。
- 真实浏览器网络对照：Edge **Beta 152.0.4191.19**，使用独立临时浏览器会话。
- 正式版 Edge **130.0.2849.80**：已用于版本检测；它低于 `DisableUpgrade` 的门槛，不声称该策略在 130 上有效。
- Stable ≥ 136、Dev、Canary：基于微软策略支持范围提供适配，**不是声称每个版本都做过真实浏览器测试**。
- CI 在 Windows 上分别运行 PowerShell 5.1 与 7，验证脚本行为，不会替代各种 Edge 版本的实机兼容性验证。

旧版遇到问题时，应先依据组织政策升级到受支持版本，或在 ≥ 123 的版本使用指定网站例外。脚本不会因为机器同时安装了 Beta，就悄悄把默认检测对象从正式版换成 Beta。

<a id="quickstart"></a>

## 快速使用：默认正式版 Edge

下载仓库 ZIP 并解压，或克隆仓库，然后在项目目录打开 PowerShell：

```powershell
git clone https://github.com/Cq-12345/edge-http-compat.git
cd edge-http-compat

# 1. 先诊断；等同于 -Action Status -Channel Stable
.\EdgeHttpCompat.ps1

# 2. 预览全局关闭自动升级，不写注册表、不创建备份、不弹 UAC
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -WhatIf

# 3. 确认这就是所需行为后应用；需要时由 Windows 请求管理员授权
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Elevate
```

运行后保存输出中的 `BackupFile` 路径。然后打开 **`edge://policy` → 重新加载策略**，检查 `HttpsUpgradesEnabled` 是否为 `false`、状态是否正常。必要时重启 Edge，使现有会话重新读取策略。

不要只凭“注册表写入成功”就判断网站问题一定解决：最后还要按原来的方式输入域名，观察实际访问结果。

### 如果 PowerShell 不允许执行脚本

先检查来源并阅读代码。下载 ZIP 带有互联网来源标记时，可在 ZIP 的“属性”中解除锁定后重新解压。也可以仅解除本项目脚本的来源标记：

```powershell
Unblock-File -LiteralPath .\EdgeHttpCompat.ps1
Unblock-File -LiteralPath .\src\EdgeHttpCompat.psm1
```

如果是个人设备的执行策略限制，可以只对**本次新进程**指定 `RemoteSigned`，不修改系统持久执行策略：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\EdgeHttpCompat.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\EdgeHttpCompat.ps1 -Action DisableUpgrade -Elevate
```

若组织的 `MachinePolicy` / `UserPolicy` 禁止执行，请联系管理员；本项目不修改组织执行策略。管理员授权由 Windows 自身处理，脚本不收集密码。

## 只允许指定网站使用 HTTP

```powershell
# 单个域名：不要包含 http://、https://、端口或路径
.\EdgeHttpCompat.ps1 -Action AllowHttp -Hostname 'legacy.example.org' -WhatIf
.\EdgeHttpCompat.ps1 -Action AllowHttp -Hostname 'legacy.example.org' -Elevate

# 多个域名：在 PowerShell 中使用数组语法
.\EdgeHttpCompat.ps1 -Action AllowHttp -Hostname 'legacy.example.org', 'intranet.example.net' -Elevate

# 域及其子域，按微软支持的 [*.] 格式填写
.\EdgeHttpCompat.ps1 -Action AllowHttp -Hostname '[*.]example.org' -Elevate
```

将 `example.org` 等示例替换成自己的主机名。脚本会转成小写、删除末尾的点、把国际化域名转换为 ASCII A-label，并去重。它会寻找未使用的数字编号追加记录，保留原有列表。

| 输入 | 处理 |
|---|---|
| `LEGACY.Example.Org` | 保存为 `legacy.example.org` |
| `legacy.example.org.` | 保存为 `legacy.example.org` |
| `[*.]example.org` | 保留为域及子域的匹配格式 |
| 国际化域名 | 转换为 IDN A-label / punycode |
| `http://example.org/a` | 拒绝：应只填写主机名 |
| `example.org:8080` | 拒绝：该策略不是按端口配置 |
| `*`、`[*]` | 拒绝：微软不允许用它们匹配所有网站 |

如果要关闭所有自动升级，请使用 `DisableUpgrade`，不要尝试用通配符伪造全局例外。`HttpAllowlist` 不覆盖 HSTS，见后面的原理和排查说明。

<a id="channels"></a>

## Beta / Dev / Canary 怎么用

**只需要加 `-Channel`，不需要编辑脚本。**

```powershell
# Edge Beta：诊断、预览、应用
.\EdgeHttpCompat.ps1 -Channel Beta
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Channel Beta -WhatIf
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Channel Beta -Elevate

# Beta 指定网站例外
.\EdgeHttpCompat.ps1 -Action AllowHttp -Channel Beta -Hostname 'legacy.example.org' -Elevate

# Dev / Canary 同理
.\EdgeHttpCompat.ps1 -Channel Dev
.\EdgeHttpCompat.ps1 -Channel Canary
```

### 关键区别：选择检测渠道，不代表隔离策略影响范围

`-Channel` 决定**找到哪个浏览器文件、读取哪个版本、执行哪个版本检查**。本工具写入的是微软文档规定的统一路径：

```text
当前用户：HKCU\Software\Policies\Microsoft\Edge
整台电脑：HKLM\Software\Policies\Microsoft\Edge
```

**不会创建 `...\Microsoft\Edge Beta` 策略路径。** 在同一个用户 / 设备作用域内，支持该策略的 Edge 渠道可能共同读取该设置。`-Channel Beta` 不能保证“只影响 Beta、不影响正式版”。如果需要让多个渠道采用互不相同的策略，应该使用分离的 Windows 用户或测试设备，并分别验证有效策略。

### 自动查找的安装目录

脚本在当前系统的 `ProgramFiles(x86)`、`ProgramFiles`、`LOCALAPPDATA` 下检查以下相对路径，不写死盘符或用户名：

| `-Channel` | 相对路径 |
|---|---|
| `Stable`（默认） | `Microsoft\Edge\Application\msedge.exe` |
| `Beta` | `Microsoft\Edge Beta\Application\msedge.exe` |
| `Dev` | `Microsoft\Edge Dev\Application\msedge.exe` |
| `Canary` | `Microsoft\Edge SxS\Application\msedge.exe` |

非标准安装路径可显式提供：

```powershell
.\EdgeHttpCompat.ps1 -EdgePath 'D:\Browsers\Edge\Application\msedge.exe'
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Channel Beta -EdgePath 'D:\Browsers\Edge Beta\Application\msedge.exe' -Elevate
```

`-EdgePath` 优先于自动发现；脚本检查文件的 Microsoft Edge 产品标识和版本。`-Channel` 在此时仍是用户选择的标签，不会对自定义路径自动推断渠道。

## 用户范围、整机范围和管理员权限

默认 `-Scope CurrentUser`，只配置发起操作的 Windows 用户。某些机器连 `HKCU\Software\Policies` 也受权限保护，因此“当前用户”并不等于“必定不需要管理员”。遇到拒绝访问时可加 `-Elevate`。

脚本在提升权限**之前**记录原用户 SID 和备份目录，子进程用 `HKEY_USERS\原SID\...` 定位原用户。即使 UAC 使用另一个管理员身份，也不会误把当前用户修复写进管理员自己的 HKCU。

```powershell
# 显式配置全机，影响所有用户；仅在确实需要时使用
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Scope LocalMachine -Elevate
```

`Status` 同时显示本地用户级和机器级的相关值。机器、域、MDM 或云管理策略可能覆盖本地设置；本地注册表输出不是有效策略的完整视图。**`edge://policy` 是检查浏览器实际采用什么策略的重要入口。** 公司或学校管理的电脑应与管理员协调，避免重复争抢同一项策略。

浏览器出现“由你的组织管理”提示可能只是因为本地加入了浏览器策略，不代表本脚本把电脑加入了某个组织或安装了远程管理工具。

## 备份与撤销

每次真正发生修改之前，脚本保存一份 JSON，默认目录是：

```text
%LOCALAPPDATA%\EdgeHttpCompat\Backups
```

可以改为自己的目录：

```powershell
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -BackupDirectory 'D:\MyBackups\EdgeHttpCompat' -Elevate
```

备份记录**本次变更涉及的值**、原值是否存在、原类型、原内容以及修改后的值；不导出整个注册表，不复制浏览器用户配置。

```powershell
# 把路径替换为应用时输出的 BackupFile
.\EdgeHttpCompat.ps1 -Action Restore -BackupFile 'D:\MyBackups\EdgeHttpCompat\edge-http-20261101T000000000Z-example.json' -WhatIf
.\EdgeHttpCompat.ps1 -Action Restore -BackupFile 'D:\MyBackups\EdgeHttpCompat\edge-http-20261101T000000000Z-example.json' -Elevate

# 原来使用全机范围的备份，恢复时也必须指定相同范围
.\EdgeHttpCompat.ps1 -Action Restore -Scope LocalMachine -BackupFile 'D:\MyBackups\machine-backup.json' -Elevate
```

撤销规则：

- 原本没有该值：删除本次添加的值；**不会擅自改成 `1`**。
- 原本有值：恢复原类型和原内容。
- 只删除本次添加的 HTTP 例外，保留既有例外和其他策略。
- 如果当前值与备份记录的“修改后”状态不同，也尚未恢复成“修改前”状态，停止并报告冲突，避免覆盖后来管理员或用户的修改。
- 恢复已经完成时，再运行会报告无需改动。
- 可能留下一个没有有效值的空注册表键；不会递归删除共享的 Edge 策略键。
- 不需要原来的 Edge 可执行文件仍然存在，但必须选择原账户和原作用域。
- 每次最多处理 1000 项变更，备份最多 1 MiB；超出时应拆分操作。遇到无法可靠恢复的原注册表类型会在写入前停止。

多项注册表写入不是系统事务。应用中途失败时会尝试撤回本次已完成且未被其他程序再改动的写入；恢复中途发生权限或并发错误时可能已有部分值恢复，应保留备份、检查报错并重试，不要删除备份。

备份属于运行数据，可能包含 SID、自定义域名和本地路径，请自行保存。不要将个人备份或原始网络日志上传到公开 Issue。提升权限时生成的 `elevation-*.log` 也保存在备份目录，便于查看失败原因。

## 为什么关闭“始终使用安全连接”后还可能升级

这里存在几个不同层次，不能只看到设置里一个开关就判断所有升级都已关闭：

1. **服务器行为**：HTTP 和 HTTPS 是不同连接。HTTP 可以返回正常页面，而同域名的 TLS 握手、证书或 HTTPS 服务有问题；网站也可能主动返回重定向。
2. **自动 HTTPS 升级**：新版 Edge 可以主动尝试将符合条件的 HTTP 导航升级成 HTTPS。`HttpsUpgradesEnabled` 控制这一机制；未配置时默认启用。`DisableUpgrade` 使用的是这个正式支持的控制项。[微软说明](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpsUpgradesEnabled)
3. **HTTPS-Only / HTTPS-First 模式**：与上面独立，用户设置或组织策略可能要求优先安全连接并显示警告。诊断会读取本地 `HttpsOnlyMode` 策略，但本工具不修改该模式，也不读取每个个人配置文件中的开关。[模式说明](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpsOnlyMode)
4. **HSTS**：网站声明或浏览器预加载列表要求使用 HTTPS。微软明确说明 `HttpAllowlist` 不适用于 HSTS 升级。[例外限制](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpAllowlist)
5. **地址栏、历史记录、扩展和代理**：它们也可能影响实际打开的地址。关闭自动升级不会把历史记录中已经保存的 HTTPS 链接重新解释成 HTTP。

因此，“输入完整 `http://` 可以访问”是一个有用的诊断线索，但不能单独证明所有自动跳转都来自同一个机制。本项目不会声称一条策略可以修复所有 HTTPS 故障。

### 项目起因中的实测证据

在一台 Edge Beta 152.0.4191.19 上，对同一个仍可通过 HTTP 正常访问的站点做了前后对照：

| 状态 | 独立浏览器会话记录的主页请求顺序 | 页面 |
|---|---|---|
| 修改前 | `HTTPS → HTTP` | 尝试升级，失败后回退并加载 |
| `HttpsUpgradesEnabled=0` 后 | `HTTP` | 直接加载，无 HTTPS 请求 |

这里证明的是**自动升级请求确实被策略关闭**。原使用者的常用窗口曾卡在 HTTPS 错误上；隔离会话里能够回退，不能把二者混为“完整复现了每个原窗口的失败”。同样，该结果不证明所有其他站点都支持 HTTP。

## 如何确认修改真正生效

1. 运行 `Status`，检查本地策略值、所选浏览器版本和作用域。
2. 在**实际使用的那个 Edge 渠道**打开 `edge://policy`，重新加载策略。
3. `DisableUpgrade` 应看到 `HttpsUpgradesEnabled = false`；`AllowHttp` 应看到包含目标主机的 `HttpAllowlist`。检查状态、来源、范围及是否被其他策略覆盖。
4. 必要时关闭并重开 Edge。脚本不强制结束浏览器进程，以免影响未保存的工作。
5. 按原来的方式输入域名，再检查地址栏最终协议及页面是否加载。需要时在开发者工具 Network 中启用 Preserve log 观察请求链。

只有把浏览器实际策略和目标页面结果都验证了，才能判断这台电脑上的问题已解决。`Status` 返回退出码 0 只表示诊断完成，不表示网站一定可访问。

<a id="troubleshooting"></a>

## 修改后仍然有问题

| 现象 | 优先检查与处理 |
|---|---|
| `Access denied` / 拒绝访问 | 使用 `-Elevate`；UAC 中由你授权。若组织限制不允许，联系管理员。 |
| 找不到 Edge | 确认所选渠道，或用 `-EdgePath` 指向真实的 `msedge.exe`。不会偷偷切换其他渠道。 |
| 正式版 130、135 等被版本检查拦截 | `DisableUpgrade` 要求 ≥ 136；不要用移除版本检查来假装策略受支持。 |
| `edge://policy` 中没有条目 | 确认当前 Windows 用户、作用域、浏览器渠道；重新加载策略或重启。 |
| 策略显示未知 / 不支持 | 检查实际浏览器版本和策略名称，参照上面的版本表。 |
| 用户级设置与机器级设置不同 | 看 `edge://policy` 的生效来源；不要假定 HKCU 总能覆盖 HKLM。 |
| 策略反复被改回 | 可能存在组织、MDM、云管理或其他配置工具；联系管理者确认。 |
| 仍提示必须安全连接 | 检查独立的 HTTPS-Only 模式及 `HttpsOnlyMode`；本工具没有关闭它。组织强制模式需由管理员处理。 |
| 明确输入 `http://` 也立即变成 HTTPS | 检查服务器重定向、HSTS、扩展、代理；不要直接删除安全策略或绕过证书警告。 |
| 输入域名时选中了历史 HTTPS 地址 | 对照全新标签页和地址栏建议，确认导航目标；本工具不清除个人历史。 |
| HTTP 也无法访问 | 排查网站服务、DNS、校园网 / 内网连接、代理等，已超出此策略的修复范围。 |
| 想只改 Beta 而其他渠道不变 | 此策略路径不按渠道隔离；见渠道章节，使用分离的账户或测试设备验证。 |
| `Restore conflict` | 当前值被后来操作修改。保留备份，查看双方内容；工具不会强行覆盖。 |

### 独立比较 HTTP / HTTPS 服务

在命令行中把示例主机替换成自己的站点：

```powershell
curl.exe --max-time 15 --output NUL --write-out '%{http_code}\n' 'http://legacy.example.org/'
curl.exe --max-time 15 --output NUL --write-out '%{http_code}\n' 'https://legacy.example.org/'
```

这只测试服务响应，不会测试 Edge 地址栏的行为。`curl` 的代理和证书环境也可能与 Edge 不同，不能仅凭它的结果排除浏览器或代理问题。不要为了让测试“成功”而随意关闭 TLS 证书验证。

## 参数参考

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Action` | `Status` | `Status` / `DisableUpgrade` / `AllowHttp` / `Restore` |
| `-Channel` | `Stable` | `Stable` / `Beta` / `Dev` / `Canary`，用于检测与版本检查 |
| `-Scope` | `CurrentUser` | `CurrentUser` / `LocalMachine` |
| `-Hostname` | 无 | `AllowHttp` 必填，支持多个主机名 |
| `-EdgePath` | 自动查找 | 自定义 Edge 可执行文件的完整路径 |
| `-BackupDirectory` | `%LOCALAPPDATA%\EdgeHttpCompat\Backups` | 新备份与提升权限日志的目录 |
| `-BackupFile` | 无 | `Restore` 必填，选择一次具体操作的备份 |
| `-Elevate` | 关闭 | 需要写入且当前未提升权限时请求 UAC；`Status` 和 `-WhatIf` 不提升 |
| `-WhatIf` | 关闭 | 预览写入 / 恢复，不执行 |
| `-Confirm` | 关闭 | 写入前使用 PowerShell 的标准确认 |
| `-Json` | 关闭 | 结构化状态或操作结果；建议自动化使用不带 `-Elevate` 的调用 |
| `-TargetUserSid` | 发起用户的 SID | 高级参数；主要用于保持提权前的用户身份，普通使用无需设置 |

退出码：`0` 表示命令成功、无需改动或仅执行预览；`1` 表示输入错误、版本不支持、权限失败或恢复冲突等。通过 `powershell.exe -File` / `pwsh -File` 调用时可检查进程退出码。

## 测试与开发

```powershell
# Windows 自带 PowerShell
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1

# PowerShell 7
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1
```

测试在随机的 `HKCU\Software\EdgeHttpCompat.Tests\<随机ID>` 和项目 `.test-artifacts` 目录中运行，结束后清理。它们不会修改真实的 Edge 策略，不需要管理员权限，不访问目标网站，也不安装测试依赖。

覆盖内容包括主机名规范化、版本门槛、默认渠道、备份 / 恢复、原值类型、重复执行、已有列表保护、恢复冲突、恶意备份目标拒绝、`WhatIf`、中途写入失败回滚，以及提权参数中数组和特殊字符的传递。真实 UAC 交互和各种浏览器版本的网络行为不由这些单元 / 集成测试完全覆盖。

```text
EdgeHttpCompat.ps1          命令入口、默认渠道、参数与提升权限
src/EdgeHttpCompat.psm1     浏览器检测、策略计划、注册表读写、备份和恢复
tests/Run-Tests.ps1         无外部依赖的 Windows 测试
.github/workflows/test.yml PowerShell 5.1 / 7 的 CI
README.en.md               English usage and design notes
```

### 如何按自己的情况改源码

- **只换渠道**：使用 `-Channel`，无需改源码。若要制作自己的默认渠道分支，同时修改入口与 `Get-EhcEdgeInstallation` 的默认值、默认渠道测试和 README。
- **安装目录不同**：先用 `-EdgePath`。要增加通用发现位置，修改 `Get-EhcEdgeInstallation` 的候选目录，并增加测试；不要硬编码某个人的用户目录。
- **增加主机匹配方式**：先核对微软支持的 `HttpAllowlist` 格式，再修改 `ConvertTo-EhcHostname` 及其测试。不能靠放宽输入验证让微软不支持的 URL 格式生效。
- **增加新策略操作**：实现对应计划、最低版本检查、备份格式验证和恢复逻辑，并测试冲突与回滚。不要将任意注册表路径直接从用户提供的备份执行。
- **微软改变版本支持**：以官方文档为依据，更新 `Assert-EhcSupportedVersion`、检测结果中的支持标记、README 版本表和边界测试；不要只改表格。
- **需要其他操作系统**：应实现该系统对应的政策配置机制和独立恢复流程，而不是复用本项目的 Windows 注册表部分。

提交 Issue 或 PR 前请阅读 [贡献说明](CONTRIBUTING.md)。项目采用 [MIT License](LICENSE)，可使用、修改和再发布。这是社区工具，不是微软官方产品。
