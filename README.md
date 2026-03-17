# Proxy Pulse

macOS 菜单栏代理诊断工具。一键确认代理是否真的在工作，出口 IP 是否符合预期。

## 功能

- **三通道代理检测**：网页端（scutil 系统代理）、终端（环境变量）、桌面应用（launchctl）独立检测，分别显示状态
- **出口 IP 检测**：通过 ipapi.co 获取当前出口 IP 及归属地、运营商，支持保存预期 IP 进行自动比对校验
- **8 个域名连通性检测**：google.com、github.com 作为基准，另检测 claude.ai、api.anthropic.com、statsig.anthropic.com、sentry.io、platform.claude.com、code.claude.com 等 Claude 相关域名，显示响应延迟
- **时区一致性检测**：对比 IP 归属时区与系统时区，代理切换后时区不一致时发出提示
- **IP 查询**：可输入任意 IP 查询归属信息（自动预填已保存目标 IP）
- **外部链接**：一键在 Safari 中打开 PixelScan / IP2Location 进行深度检测
- Liquid Glass 卡片 + 系统材质背景，自动适配深色模式
- 常驻菜单栏，无 Dock 图标，纯诊断只读，不注入任何东西

## 使用

- 左键点击菜单栏图标 → 打开/关闭诊断面板
- 右键点击 → 退出
- 点击面板外 → 自动收起

## 构建

```bash
bash build.sh
cp -r "Proxy Pulse.app" /Applications/
open "Proxy Pulse.app"
```

需要：macOS 26+ / Xcode Command Line Tools（`xcode-select --install`）

## GitHub

https://github.com/taozhe6/ProxyPulse
