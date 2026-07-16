---
kind: frontend_style
name: Admin UI 前端样式系统（原生 CSS + 设计令牌）
category: frontend_style
scope:
    - '**'
source_files:
    - admin/ui/style.css
    - admin/ui/index.html
    - admin/ui/app.js
---

vhttpd 的前端风格集中在 admin/ui/ 目录，是一个纯静态单页管理控制台，由 vhttpd 主进程直接通过 HTTP 提供。整体采用零依赖的轻量方案：一个 HTML、一个 CSS、一个 JS，无任何构建工具或组件库。

1. 样式体系与主题
- 使用 CSS 自定义属性集中定义设计令牌，位于 :root，包括背景色、表面色、边框色、文本色、强调色、危险/成功/警告语义色等，并通过 color-scheme: light 声明浅色模式。
- 字体栈优先使用系统字体族 ui-sans-serif, system-ui, -apple-system, BlinkMacFont, Segoe UI，代码区域使用 ui-monospace, SFMono-Regular, Menlo, Consolas。
- 全局 box-sizing: border-box，body 最小宽度 320px，确保移动端可读性。

2. 布局与结构
- 页面以 .shell 为根 Grid，左侧固定 236px 侧边栏，右侧自适应内容区；在 860px 断点下退化为单列堆叠布局。
- 内容区分为 .topbar（标题加操作按钮）和 .main（视图容器），各视图通过 .view 加 .hidden 切换显示。
- 常用布局类：.grid、.split、.form-grid、.bar-list、.health-grid、.graph-list 等，配合 minmax() 实现弹性网格。

3. 组件化样式约定
- 面板：.panel 加 .panel-header 加 .panel-body 三段式卡片，统一圆角 8px、边框与内边距。
- 指标卡：.metric 包含 label/value/sub 三行，用于 Dashboard/Observability 关键数字展示。
- 标签胶囊：.pill 及其变体 .blue / .gray / .red，用于状态、类型、计数等小标签。
- 表格：table 使用 table-layout: fixed，表头带浅灰背景，单元格可换行。
- 按钮：.button 基础样式，.primary 强调色填充，.danger 红色描边；侧边栏按钮用 .side-button。
- 模态框：.modal 加 .modal-backdrop 加 .modal-panel 加 .modal-header 加 .modal-body，最大宽度 940px，支持滚动。
- 代码编辑器：.code-editor 通过绝对定位叠加 textarea/highlight/lines 三层，支持只读模式 .readonly，行号列宽 48px，高亮层 pointer-events: none。

4. 可视化与图表
- 拓扑图：SVG 绘制，节点按 domain 分类着色（listener/pipeline/adapter/engine），连线区分 ingress/egress/uses_engine，热路径加粗。
- 趋势折线：.sparkline 内嵌 SVG path 加 area，根据历史采样动态计算坐标。
- 进度条：.bar-track 加 .bar-fill 组合，百分比宽度驱动。

5. 响应式策略
- 单一 @media (max-width: 860px) 断点，将双列 grid 退化为单列，侧边栏恢复静态定位，顶部栏改为纵向排列。
- 大量使用 minmax(0, 1fr)、auto-fit、minmax(...) 保证在不同屏幕下的弹性适配。

6. 交互与行为
- 所有视图切换、数据拉取、草稿编辑、发布等操作由 app.js 通过原生 fetch 调用 /admin/* REST 接口完成，无框架绑定。
- 内置简易 TOML/TS/JSON 语法高亮与行号同步，不依赖第三方编辑器。

7. 开发者约定
- 新增 UI 元素应复用已有 class（如 .panel、.pill、.button），避免内联样式。
- 颜色必须从 :root 变量取值，不得硬编码十六进制值。
- 新增视图需遵循 .view 加 id=view-xxx 加 .hidden 的显隐约定，并在导航按钮中注册 data-view。
- 代码编辑器统一使用 .code-editor 结构，保持行号/高亮/输入层对齐。