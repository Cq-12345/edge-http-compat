# Contributing / 参与贡献

欢迎提交可复现的问题、文档改进和 PR。讨论可以使用中文或英文。

## 报告问题

请提供 Windows 版本、PowerShell 版本、Edge 渠道和完整版本号、运行的命令（先替换私人域名和路径）、预期行为与实际行为。

如果涉及策略，请描述 `edge://policy` 中相关条目的状态、来源和范围。不要公开浏览器配置目录、Cookie、登录信息、原始网络日志、含 SID 的个人备份或未处理的诊断输出。

不要把“注册表值存在”与“浏览器实际采用策略”混为一谈。HTTP 服务、HTTPS 服务、地址栏补全与浏览器升级机制应分别说明。

## 修改代码

1. 在分支中修改，保持 PowerShell 5.1 兼容性；脚本源码使用 ASCII，文档可使用 UTF-8。
2. 在 PowerShell 5.1 和 PowerShell 7 中运行 `tests/Run-Tests.ps1`。
3. 新增策略必须包含官方文档依据、最低版本、作用域、备份 / 恢复、冲突处理和相应测试。
4. 不引入默认联网、默认提权、自动结束用户浏览器进程或发布私人诊断数据的行为。
5. 测试只能操作自己的临时文件与测试注册表子键；不要改动开发者的真实 Edge 策略。
6. 文档区分官方支持范围、实际测试版本和尚未验证的组合。

## English

Include OS, PowerShell version, Edge channel/version, a sanitized command, expected behavior, and observed behavior. For policy issues, describe the relevant `edge://policy` status/source/scope. Do not attach personal browser profiles, credentials, raw network logs, unredacted backups, SIDs, or private diagnostic data.

Keep PowerShell 5.1 compatibility and run the test suite on 5.1 and 7. New policy operations need official support evidence, version checks, scoped writes, backups, conflict-aware restoration, and tests. Use only isolated test registry keys. Distinguish documented compatibility from actually tested browser versions.
