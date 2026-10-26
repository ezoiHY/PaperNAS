# Paper NAS

**把论文、原文证据和研究判断放在自己的服务器上。**

[![CI](https://github.com/ezoiHY/PaperNAS/actions/workflows/ci.yml/badge.svg)](https://github.com/ezoiHY/PaperNAS/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](../LICENSE)

Paper NAS 是一个可以部署在 NAS、家庭服务器或本机上的科研工作台，包含网页客户端和原生 Mac App。论文、PDF、图表、笔记、原文证据、研究判断与后台任务统一保存在服务器。

当前版本为 **0.5.0 · 早期版本 · AGPL-3.0-only**。一台服务器对应一个个人工作空间，多台设备共享；尚未提供多用户权限隔离。

[安装步骤](../README.md#quick-start) · [完整截图](SCREENSHOTS.md) · [部署说明](DEPLOYMENT.md) · [English](../README.md)

![网页文库](images/library-light.jpg)

截图来自实际运行的应用，全部使用虚构示例论文与研究记录。图中的示意图不代表经过验证的科研结果。

## 从阅读到可追溯的研究判断

1. **收集论文**：导入 PDF、论文网址、DOI 或 arXiv 标识符；检索结果先进入候选库，再由你筛选。
2. **阅读原文**：查看原始 PDF、解析文本和图表，记录与具体版本和页码对应的笔记。
3. **组织证据**：围绕一个研究问题关联多篇论文，保存准确引文或图表，并保留原始来源。
4. **形成与修订判断**：写下判断、验证计划与外部实验结果，保留修订历史，逐步更新理解。

模型辅助分析和跨论文比较是可选功能。普通阅读、笔记和研究记录不需要模型服务；开启后，由服务器向你配置的 OpenAI 兼容服务发送有界原文片段。

## 网页与原生 Mac 客户端

![Mac 原生 PDF 阅读器与页码笔记](images/macos-reader.jpg)

| 原始图表与区域修正 | 研究问题与原文证据 |
| --- | --- |
| ![图表视图](images/figures.jpg) | ![研究证据](images/research-evidence.jpg) |

更多文库、深色模式、移动端、验证计划和任务页截图见 [完整图集](SCREENSHOTS.md)。

## 包含什么

- `backend/`：独立 FastAPI/PostgreSQL 后端、文档处理、持久任务与模型接入。
- `frontend/`：真正连接 v2 API 的网页客户端，采用「专注书库」风格，无 CDN 或前端构建依赖。
- `macOS/`：SwiftUI/PDFKit 原生应用，设备凭证保存到钥匙串。
- `deploy/`：Docker 与 systemd 部署模板。
- `legacy/`：旧版适配服务和维护脚本，作为历史源码保留；新安装不需要它。

支持导入、搜索、分组、候选筛选、PDF/图表阅读、笔记、研究问题、证据、判断修订、验证计划、结果记录、跨论文比较、导出，以及任务和模型设置。每日检索只收集候选，不自动花费模型额度做深读。

## 开始使用

按根目录 [README](../README.md#quick-start) 启动 PostgreSQL、API 和 worker，再打开 `http://127.0.0.1:8788/app/`。访问密钥在服务器终端用 `papernas-v2 show-access-key` 获取。Mac App 连接同一服务器。

原生应用构建：`bash scripts/build-app.sh release`，输出 `dist/Paper NAS.app`。当前本机构建为临时签名，不能当作已经过 Apple 公证的正式安装包。

网页界面使用英文；现有 Mac 界面主要使用中文。网页 PDF 笔记使用手动页码和引文，Mac 支持原生文字选择与区域锚点。网页中的 Markdown/公式显示采用保守文本方式，原生阅读器的排版更完整。

## 部署与数据

参见 [部署说明](DEPLOYMENT.md)、[架构](ARCHITECTURE.md)、[功能边界](FEATURES.md)。远程访问使用 HTTPS 或可信私网，数据库不对外开放。备份必须同时保留 PostgreSQL 和完整状态目录。

公开仓库不包含个人论文库、密钥、连接文件、数据库、模型输出、缓存、历史部署记录或旧安装包。项目源码采用 [AGPL-3.0-only](../LICENSE)，第三方组件保留各自许可。

模型生成内容仍需要核对；引用匹配只说明原文存在相应文字，不代表结论可靠。语义检索、Zotero 同步、OCR、自动科研实验以及多用户权限尚未实现。

## 参与项目

欢迎提交 [问题报告和功能建议](https://github.com/ezoiHY/PaperNAS/issues)。贡献前请阅读 [CONTRIBUTING.md](../CONTRIBUTING.md)，界面问题尽量附上使用示例数据的截图。安全问题按 [SECURITY.md](../SECURITY.md) 处理。

测试范围和已知限制见 [验证记录](VERIFICATION.md)。
