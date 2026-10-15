# 交互设计稿 / 概念介绍页

[agentos-interaction-design.html](agentos-interaction-design.html) 是 Personal AgentOS 的交互设计稿，同时也是项目的**概念介绍页**。

- **在线访问**：https://dyman1024.github.io/AgentOS/ 。由 GitHub Pages 从 `main` 分支的 `docs/` 目录发布，`docs/index.html` 会跳转到本页。
- **本地查看**：用浏览器直接打开这个文件。字体来自 Google Fonts，离线时会回退到系统字体。

页面内容依据[产品愿景](../vision/personal-agentos.md)和[技术方案](../architecture/README.md)：

| 段落 | 内容 |
|---|---|
| 首屏 | 「一台会生长的电脑」：在输入框里打一句话，对应的应用图标就从输入框里长出来，并接入一张彼此连通的网络 |
| 01 理念 | 应用是生成的 / 协议天生互联 / Agent 是主人 |
| 02 交互原型 | 一个可以操作的 AgentOS 窗口 |
| 03 系统剖面 | 六层 3D 分解图，每层对应技术方案的一份分册 |
| 04 设计语言 | 颜色、字体、动效、组件规范 |

交互原型包含四个场景：一句话生成应用、应用之间互联、自主行动与授权、撤销与回滚。可以打开「交互标注」查看每个区域的设计说明，可以切换权限模式，生成的贪吃蛇也能真的玩。

**适配**：
- 桌面宽度 1280 以上体验最佳。
- 平板和手机都能浏览；手机上原型窗口可以左右滑动。
- 遵循系统的「减少动态效果」设置。

## 封面图

[cover.png](cover.png) 用于项目 README 和分享卡片。改了页面后可以重新生成；`?still` 参数会让页面直接显示最终状态，跳过入场动画。

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --window-size=1440,900 --virtual-time-budget=7000 --screenshot=docs/design/cover.png "file://$PWD/docs/design/agentos-interaction-design.html?still"
```
