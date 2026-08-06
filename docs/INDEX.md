# 字在 — 文档索引

个人自用的沉浸式码字 App。Flutter 单代码库，目标平台：Windows / macOS / Android。

## 设计文档（docs/app/）

| 文档 | 内容 |
|---|---|
| [README.md](app/README.md) | 产品定位、核心概念、信息架构、数据模型、全局交互原则 |
| [ui-shell.md](app/ui-shell.md) | 主界面壳布局与自适应规则 |
| [ui-sidebar.md](app/ui-sidebar.md) | 笔记本/章节树侧边栏布局与交互 |
| [ui-editor.md](app/ui-editor.md) | 编辑器布局、自动保存、字数统计、沉浸模式 |
| [ui-settings.md](app/ui-settings.md) | 设置页布局与设置项 |
| [style.md](app/style.md) | 视觉风格规范：极简留白、设计 token、字体、动效 |
| [sync.md](app/sync.md) | 云同步设计：R2 基准、Worker 网关、协议、冲突与安全 |
| [update.md](app/update.md) | 更新机制与版本体系：App 版本 / DB schema 版本 / 迁移 |

## 交付计划（docs/plan/）

| 文档 | 内容 |
|---|---|
| [README.md](plan/README.md) | 计划/任务/评审循环说明 |
| [analysis/requirements.md](plan/analysis/requirements.md) | 需求分析：场景、功能、非功能约束、范围 |
| [analysis/modules.md](plan/analysis/modules.md) | 模块分解、集成枚举、任务拆分依据 |
| [tasks/](plan/tasks/) | 任务文件 |
| [backlog.md](plan/backlog.md) | 非阻塞待办 |

## 约定

- 术语定义见 [app/README.md](app/README.md#核心概念)，全库统一。
- 代码标识符、包名、文件名使用英文；文档正文使用中文。
- 实现与文档冲突时，先改文档再改代码（atomic delivery）。
