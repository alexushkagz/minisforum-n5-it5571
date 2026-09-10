# v0.2.1 — Unraid WebGUI CSS isolation fix

## English

This maintenance release fixes CSS from the plugin's sensor page leaking into
the surrounding Unraid Plugins page. The leak could produce unreadable light
text on a light background when macOS used dark appearance while Unraid used
the `white` theme.

Changes:

- Removed the standalone `DOCTYPE`, `html`, `head`, and `body` wrapper from the
  embedded Unraid `.page` file.
- Scoped every CSS rule to the unique `#minisforum-n5-it5571-page` container.
- Removed `prefers-color-scheme`; the page now follows Unraid's own theme
  variables (`white`, `black`, `gray`, and `azure`).
- Preserved live PWM, RPM, and temperature refresh behavior.
- No kernel driver, EC register, fan-control, hardware-profile, or safety logic
  changes. The packaged kernel module is unchanged from v0.2.0.

Users of v0.2.0 should upgrade to v0.2.1, especially if the Plugins page has
mixed colors or low-contrast text.

## 中文

本维护版本修复插件传感器页面的 CSS 污染 Unraid 整个“插件”页面的问题。当
macOS 使用深色外观、而 Unraid 使用 `white` 主题时，该问题可能导致浅色背景上
出现接近白色的文字，难以阅读。

变更内容：

- 从嵌入式 Unraid `.page` 文件中移除独立网页使用的 `DOCTYPE`、`html`、
  `head` 和 `body` 外壳。
- 所有 CSS 规则均限定在唯一容器 `#minisforum-n5-it5571-page` 内。
- 移除 `prefers-color-scheme`，改为跟随 Unraid 自身的主题变量，兼容
  `white`、`black`、`gray` 和 `azure` 主题。
- 保留 PWM、转速和温度数据的实时刷新功能。
- 本版本没有修改内核驱动、EC 寄存器、风扇控制、硬件配置或安全逻辑；打包的
  内核模块与 v0.2.0 相同。

建议 v0.2.0 用户升级到 v0.2.1，尤其是遇到插件页面混合配色或文字对比度异常的
用户。
