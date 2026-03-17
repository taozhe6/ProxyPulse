# 🧭 Proxy Pulse

原生 macOS SwiftUI 应用。打开任何东西之前 — 先看它一眼。

- 显示当前公网 IP + 城市/地区/运营商
- 检测 GUI 应用能否读到代理环境变量
- 从 Google 到 Claude 逐个测试域名连通性
- 支持保存目标出口 IP，查询页自动预填并和当前出口 IP 实时对比

## 构建

```bash
cd ProxyPulse
chmod +x build.sh
bash build.sh
```

需要: macOS 13+ / Xcode Command Line Tools (`xcode-select --install`)

## 运行

```bash
open "Proxy Pulse.app"
# 或拖到 /Applications
cp -r "Proxy Pulse.app" /Applications/
```

## 工作原理

应用使用 `URLSession` 发起网络请求，它会继承 `launchctl setenv` 设置的代理环境变量。
如果你看到 Claude 域名全部 ✅，说明代理配置正确，可以放心打开 Claude Desktop。
如果看到 ❌，说明 GUI 应用没有走代理，需要先配置 launchctl 环境变量。
