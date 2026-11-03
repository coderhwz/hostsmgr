# HostsMgr

用 SwiftUI + AppKit 编写的轻量 macOS Hosts 管理器，macOS 13+，无第三方依赖。

Native macOS hosts manager built with SwiftUI and AppKit. Lightweight, dependency-free, with local/remote profiles, menu bar switching and SwitchHosts migration. macOS 13+, MIT licensed. The current interface is in Simplified Chinese.

## 功能

- 本地配置：创建、重命名、复制、删除，编辑自动保存。
- 多配置组合：打开开关选择配置，再点击「应用到系统」。菜单栏点击配置会切换选择并立即申请应用。
- 原生等宽编辑器：IP / 注释高亮、撤销、⌘F 查找、映射统计、IPv4 / IPv6 与域名格式检查。
- 远程订阅：HTTP(S) 手动刷新，UTF-8，最大 5 MB。更新后手动应用，不进行后台轮询。
- 合并预览；只替换 HostsMgr 标记区段，保留其他系统规则及注释。
- 导入 UTF-8 Hosts 文本或本应用 JSON；导出全部配置。导入配置默认停用。
- SwitchHosts 迁移：自动检测本机旧版/v5 数据目录，也可选择 v3/v4/v5 导出 JSON；预览后追加配置，跳过重复项，保留迁移前的配置备份。
- 每次写入前备份，保留最近 20 份；支持从备份恢复整个系统 Hosts。
- 原生菜单栏、深浅色适配，关闭窗口后保留菜单栏，⌘Q 完全退出。

参考 [SwitchHosts](https://github.com/oldj/SwitchHosts) 的配置管理与快速切换体验。本版本聚焦日常切换，不包含分组、定时订阅和 HTTP API。SwitchHosts JSON 请使用专门的迁移入口。

## 构建与使用

需要 Xcode Command Line Tools / Swift 5.9+：

```sh
swift test
./scripts/build-app.sh
open dist/HostsMgr.app
```

构建脚本生成当前机器架构的 Release 应用，使用本机临时签名。当前已验证 Apple Silicon，Intel 尚未实机验证。应用未公证；没有安装常驻提权服务。

1. 新建配置，填写如 `127.0.0.1 app.test` 的映射。
2. 打开需要组合的配置开关；点击眼睛按钮检查最终内容。
3. 点击「应用到系统」（⌘S），在 macOS 授权弹窗中确认。
4. 停用全部配置并应用，即移除本应用的管理区段。

每次实际写入都需要系统管理员授权。写入完成后尝试清理系统 DNS 缓存；浏览器自己的 DNS 缓存可能需要重启浏览器。

多个已选配置按侧栏顺序合并，同一域名的冲突不会自动改写；应用前请检查预览。已有 SwitchHosts 区段会原样保留，迁移时应先在原应用中停用旧规则，避免重复映射或两个应用互相覆盖。

## 从 SwitchHosts 迁移

侧栏底部「… → 从 SwitchHosts 迁移…」，或菜单「File → 从 SwitchHosts 迁移…」。

默认检测 `~/.SwitchHosts`，显示新增配置、重复数量和兼容性说明；也可以选择其他数据目录或导出的 JSON 备份。支持旧版 `data/list/tree.json` + PotDb 内容目录、v5 `manifest.json` + `entries/`，以及 v3/v4/v5 导出的 JSON。

迁移保留配置内容、侧栏顺序和 HTTP(S) 订阅地址。文件夹按「父文件夹 / 配置名」展开；系统 Hosts 节点不导入，分组引用暂不导入并显示说明。无法继续订阅的远程类型会保留缓存内容为本地配置。名称、内容、订阅地址均相同的配置会跳过，重复迁移不会重复追加。

导入配置全部停用，不刷新订阅，不修改系统 Hosts，也不改动 SwitchHosts 的源数据。确认迁移前保存 `profiles-before-migration-<UUID>.json` 到本应用数据目录。先在 SwitchHosts 中停用原配置并退出，再在 HostsMgr 启用需要的配置并应用。

## 数据与恢复

- 配置：`~/Library/Application Support/HostsMgr/profiles.json`
- 写入前备份：`~/Library/Application Support/HostsMgr/Backups/`
- 首次写入额外保存：`/etc/hosts.hostsmgr-backup`，以后不覆盖。
- 点击侧栏底部「… → 恢复系统 Hosts 备份…」，选择一份文本备份并确认恢复。恢复会替换整个 Hosts，并先备份当前版本；不会改动已保存的配置。

系统写入采用同目录临时文件与重命名，保留原文件权限/属主。授权后再次比对原始内容，发现并发修改则拒绝覆盖。损坏或重复的 HostsMgr 区段标记会阻止组合应用。系统 Hosts 不应使用符号链接。

## 资源占用与验证

2026-11-03 在本机 Apple Silicon / macOS 27.0.1，Release 版本、两个小配置、主窗口打开、空闲时单次测量：

| 指标 | 测量结果 |
| --- | --- |
| `footprint -p <PID>` 物理内存 Footprint | 约 35 MB |
| `ps` RSS（包含共享映射等） | 约 118 MB |
| `ps` 空闲 CPU | 0.0% |
| 可执行文件 | 约 1 MB |

内存指标口径不同，35 MB 不代表 RSS；大型订阅和长时间使用尚未基准测试。无 WebView、网络定时器或后台轮询；高亮在编辑后合并执行，超过 256K 字符停止全量高亮。

6 项自动测试覆盖区段合并、停用、原规则保留、损坏标记、格式检查，以及临时文件上的真实 shell 写入 / 备份 / 并发保护 / 超过命令参数上限的大文件写入。UI 已验证编辑、开关、映射统计、合并预览。未实际授权改写本机 `/etc/hosts`，管理员授权链路及不同 macOS 版本仍需实际验收。

另有迁移测试覆盖旧版目录、v3/v4/v5 备份、v5 内容文件、重复检查、默认停用、损坏数据及路径越界拒绝。如需对自己的非空旧版数据目录执行只读检查，可用 `HOSTSMGR_SWITCHHOSTS_TEST_PATH="$HOME/.SwitchHosts" swift test`；普通测试会跳过本机数据检查。

## 参与与许可

欢迎提交 Issue 和 Pull Request，开发方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。GitHub Actions 会运行测试、打包当前 runner 架构的应用并上传构建产物；构建 ZIP 可以在对应工作流运行的 Artifacts 中下载。

本项目采用 [MIT License](LICENSE)。界面与功能参考 SwitchHosts，Swift 代码与图标为本项目实现；项目不附带或上传用户的 Hosts 配置。迁移兼容性参考 [SwitchHosts 存储与导入导出实现](https://github.com/oldj/SwitchHosts/tree/master/src-tauri/src)，不代表与 SwitchHosts 官方存在关联。
