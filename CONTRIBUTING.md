# 参与开发

欢迎提交 Issue 和 Pull Request。请描述使用的 macOS 版本、机器架构、复现步骤及预期行为；涉及 Hosts 内容时使用示例域名，不要上传真实内网映射、令牌或订阅凭据。

开发需要 macOS 13+ 和 Swift 5.9+。项目使用 Swift Package Manager，无第三方依赖。

```sh
swift test
./scripts/build-app.sh
open dist/HostsMgr.app
```

请保持改动聚焦，并为配置解析、迁移和系统写入逻辑添加相关测试。自动测试只使用临时文件，不应写入实际 `/etc/hosts`，也不应要求管理员权限或连接真实订阅服务。

`HOSTSMGR_SWITCHHOSTS_TEST_PATH` 是可选的本机数据只读检查，普通测试和 CI 不需要设置。不要把本机 SwitchHosts 数据、HostsMgr 配置和备份加入仓库。

提交贡献即表示同意将贡献按本项目的 MIT 许可证授权。
