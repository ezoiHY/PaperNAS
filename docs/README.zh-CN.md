# Paper NAS

**用原生 Mac App 阅读论文、整理证据，把研究工作留在自己的服务器上。**

[![CI](https://github.com/ezoiHY/PaperNAS/actions/workflows/ci.yml/badge.svg)](https://github.com/ezoiHY/PaperNAS/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](../LICENSE)

Paper NAS 是一个以原生 Mac 阅读体验为核心的科研工作台，同时提供网页客户端。用 SwiftUI/PDFKit 阅读原始论文，在精读正文中查看公式、追溯引用，再把证据整理到研究问题中。论文库、研究记录与后台任务统一保存在自己的 NAS、家庭服务器或本机上。

当前版本为 **0.5.0 · 早期版本 · AGPL-3.0-only**。一台服务器对应一个个人工作空间，多台设备共享；尚未提供多用户权限隔离。

[Mac 完整导览](MACOS-GALLERY.md) · [安装步骤](../README.md#quick-start) · [网页图集](SCREENSHOTS.md) · [部署说明](DEPLOYMENT.md) · [English](../README.md)

![原生 Mac 精读页面：章节目录、正文排版与原文引用](images/macos-analysis.jpg)

截图来自实际运行的应用，全部使用虚构示例论文与研究记录；分析文字和示意图不代表真实科研结论。Mac 界面目前主要使用中文。

## 从阅读到可追溯的研究判断

1. **收集论文**：导入 PDF、论文网址、DOI 或 arXiv 标识符；检索结果先进入候选库，再由你筛选。
2. **阅读原文**：查看原始 PDF、解析文本和图表，记录与具体版本和页码对应的笔记。
3. **组织证据**：围绕一个研究问题关联多篇论文，保存准确引文或图表，并保留原始来源。
4. **形成与修订判断**：写下判断、验证计划与外部实验结果，保留修订历史，逐步更新理解。

模型辅助分析和跨论文比较是可选功能。普通阅读、笔记和研究记录不需要模型服务；开启后，由服务器向你配置的 OpenAI 兼容服务发送有界原文片段。

## 原生 Mac App，逐个界面看

<table width="100%">
  <tr>
    <td width="50%" valign="top">
      <p><strong>图文书架</strong></p>
      <a href="images/macos-library-grid.jpg"><img src="images/macos-library-grid.jpg" alt="原生图文书架" width="100%"></a>
      <p>通过论文预览、分组与搜索浏览文库。</p>
    </td>
    <td width="50%" valign="top">
      <p><strong>PDF 与笔记</strong></p>
      <a href="images/macos-pdf-notes-light.jpg"><img src="images/macos-pdf-notes-light.jpg" alt="PDF 阅读与侧栏笔记" width="100%"></a>
      <p>阅读原始页面，让笔记对应具体来源。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <p><strong>专注精读</strong></p>
      <a href="images/macos-focus-reading.jpg"><img src="images/macos-focus-reading.jpg" alt="原生专注精读与行内公式" width="100%"></a>
      <p>专注于正文，随时查看公式与原文引用。</p>
    </td>
    <td width="50%" valign="top">
      <p><strong>原始图表</strong></p>
      <a href="images/macos-figures.jpg"><img src="images/macos-figures.jpg" alt="Mac 原始图表阅读器" width="100%"></a>
      <p>放大图表、修正区域，并返回来源页。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <p><strong>研究证据</strong></p>
      <a href="images/macos-research-evidence.jpg"><img src="images/macos-research-evidence.jpg" alt="Mac 研究证据" width="100%"></a>
      <p>围绕一个问题关联论文、引文与图表。</p>
    </td>
    <td width="50%" valign="top">
      <p><strong>判断与计划</strong></p>
      <a href="images/macos-research-plans.jpg"><img src="images/macos-research-plans.jpg" alt="Mac 判断和验证计划" width="100%"></a>
      <p>记录判断依据，明确接下来的验证方法。</p>
    </td>
  </tr>
</table>

**[查看完整 Mac 导览](MACOS-GALLERY.md)**：17 张完整截图，继续展示证据保存、跨论文比较、后台任务与深色模式。

## 在浏览器中继续使用

![网页文库](images/library-light.jpg)

网页与 Mac 共享同一个后端和研究工作空间；关闭客户端后，后台任务仍由服务器继续处理。[网页图集](SCREENSHOTS.md) 展示桌面、移动端和深色模式。

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
