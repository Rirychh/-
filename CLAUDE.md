# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 這個 Repo 是什麼

808 AI 五金行（808aiworkshop.com）的靜態網站頁面。目前包含 Hermes Agent 完整介紹與安裝教學頁（`index.html`），純 HTML + CSS + 少量 Vanilla JS，無框架、無建置工具、無依賴套件。

## 開發與預覽

直接用瀏覽器開啟 `index.html` 即可預覽，或用任意靜態伺服器：

```bash
# Python（最常見）
python3 -m http.server 8080

# Node.js（若有 npx）
npx serve .
```

沒有 build step，沒有 lint 設定，沒有測試框架。

## 頁面架構（index.html）

單一 HTML 檔案，CSS 全部 inline 在 `<style>` 內，結構如下：

- **Nav**（`.nav-808ai`）：sticky 頂部導覽，連結至 808aiworkshop.com 各子頁
- **Hero**（`.hero`）：標題 + badge + subtitle
- **Main container**（`.container`，max-width 880px）：依序放 10 個 section
- **CTA section**：三個 call-to-action 按鈕
- **Footer**

### CSS 設計語言

CSS 變數定義在 `:root`，主要色系：

| 變數 | 用途 |
|------|------|
| `--hermes: #7C3AED` | 主題紫色（按鈕、強調、連結） |
| `--primary: #E8751A` | 808AI 品牌橘色（tip box） |
| `--bg: #FAF5F0` | 頁面背景 |
| `--card: #FFFFFF` | 卡片背景 |

### 元件類別

- `.feature-card` / `.feature-grid`：兩欄 grid 卡片
- `.install-box`：深色代碼區塊（`#1e1e2e` 背景，綠色文字 `#a6e3a1`）
- `.compare-table`：比較用表格
- `.highlight`：紫色提示框（`--hermes-light` 背景）
- `.tip`：橘色小提示（`--primary-light` 背景）
- `.warn`：黃色警告框
- `.steps` + `.step`：CSS counter 自動編號步驟

### 動畫

用 `IntersectionObserver` 觸發 `.fade-up` → `.fade-up.visible`，threshold 0.15。

## 新增頁面時的慣例

新頁面應維持相同設計系統：
1. 複製現有 `index.html` 的 `<head>`、nav、footer、CSS 變數區段
2. 在 `.nav-808ai-items` 加入對應連結，並在當前頁加上 `nav-808ai-active` class
3. 字型來源：Google Fonts（Noto Sans TC、Noto Serif TC、Inter、JetBrains Mono）

## 部署

靜態頁面，可直接部署到 GitHub Pages（從 `main` 或指定分支的根目錄）或任何靜態托管服務。
