# Proxy Pulse

macOS 菜单栏常驻代理诊断工具。点一下就知道能不能用 Claude。

## 功能

- 菜单栏常驻，不占 Dock
- 三通道代理状态检测（网页 / 终端 / 桌面应用）
- 当前出口 IP + 城市/地区/运营商
- 8 个域名连通性测试（Google、GitHub、Claude 全家桶）
- 可保存目标出口 IP，自动校验是否匹配
- IP 查询面板（自动预填已保存目标 IP）
- Liquid Glass 卡片 + 系统毛玻璃背景，自动适配深色模式
- 纯诊断，不注入任何东西，退出零副作用

## 使用

- 左键点击菜单栏图标 → 打开/关闭诊断面板
- 右键点击 → 退出
- 点击面板外 → 自动收起

## 构建

```bash
bash build.sh
open "Proxy Pulse.app"
# 安装到 Applications
cp -r "Proxy Pulse.app" /Applications/
```

需要: macOS 26+ / Xcode Command Line Tools (`xcode-select --install`)
