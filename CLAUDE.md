# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 這個 Repo 是什麼

808 AI 五金行（808aiworkshop.com）的靜態網站頁面。純 HTML + CSS + 少量 Vanilla JS，無框架、無建置工具、無依賴套件。

目前頁面：

| 檔案 | 內容 | 線上路徑 | accent 色 |
|------|------|----------|-----------|
| `index.html` | Hermes Agent 完整介紹與安裝教學 | `/hermes-agent` | 紫 `#7C3AED` |
| `image-cards.html` | 圖卡量產工作流（三角分工 + 審核標準） | `/808aiimagecards` | teal `#0F766E` |

## 做事的方式（交付型任務）

產出物會被別人拿去用、或同一類事之後還會再做時，照這幾條走。
單純問答、查個事實、一兩步的小事不適用——那些直接做比較快。

1. **動手前先寫驗收標準**：3–7 條，每條要能被不認識這任務的人判出過／退，
   每條標 `[程式]` 或 `[人眼]`。標了 `[程式]` 就真的寫成腳本——
   事後才寫的標準會被已經做出來的東西反向定義。
2. **做完先停，換上審的身分**逐條判定並寫下來。全過才算過，任一條沒過就是退。
3. **同一種改法最多試兩次**，之後換維度：縮小範圍／降低精細度／換方法。
   換路是換維度，不是換措辭。
4. **卡住時帶著失敗紀錄回報**：試過哪幾種、各差在哪，附 2–3 個具體選項，
   不要說「做不到」，也不要開放式反問。
5. **前提錯了、需求本身矛盾、要動到沒被授權的範圍、缺只有人知道的關鍵資訊**
   —— 這四種不必跑滿重試次數，立刻回報。硬試下去最糟的不是失敗，
   是湊出一個看起來成功的東西。

完整方法論（任務卡、反例對照、換路細節）在 `.claude/skills/problem-workflow/`，
用 `/problem-workflow` 叫出來。實測過它無法靠自動觸發，原因見該目錄的
`evals/RESULTS.md`——所以核心幾條放在這裡，需要全套時自己叫。

## Skills

這個 repo 帶兩個 skill，一個是通用模式，一個是它的實例。

### `problem-workflow` — 解決問題的通用工作流

不限題材。核心是：做與審分開、驗收標準在動手前寫成明文、能機械判的真的
寫成程式、重試給上限、卡住時帶著失敗紀錄回報。

```
.claude/skills/problem-workflow/
├── SKILL.md                        # 三個角色 + 五步 + 重試上限 + 何時別用
├── assets/task-card.md             # 可直接複製去填的任務卡
└── references/
    ├── acceptance.md               # 怎麼寫可逐條判的標準（三問法、反例對照）
    ├── retry.md                    # 換路規則、不必跑滿預算的情況、回報格式
    └── example-image-card.md       # 套在圖卡上的完整對照
```

### `image-card` — 圖卡生成工作流（上面那套模式的實例）

`.claude/skills/image-card/` 是 `image-cards.html` 那套流程的可執行版本：
使用者只講需求，Claude 寫畫圖指令、送去產圖、照五條標準審圖、沒過改指令重畫。

```
.claude/skills/image-card/
├── SKILL.md                      # 五步流程主文件
├── scripts/check_image.py        # 比例與解析度的機械判定（需 Pillow）
└── references/
    ├── prompt-template.md        # 畫圖指令模板 + 平台→比例對照
    ├── characters.md             # 角色設定卡登錄（咪卡）
    └── review.md                 # 五條審核標準、判定格式、重試上限
```

新增角色時改 `references/characters.md`；調整審核標準改 `references/review.md`。
`image-cards.html`（給人看）與這個 skill（給 Claude 跑）講的是同一套流程，
改其中一邊時記得同步另一邊。

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

CSS 變數定義在 `:root`。**每頁有自己的 accent 色**（`index.html` 用 `--hermes` 紫，`image-cards.html` 用 `--accent` teal），其餘 token 兩頁一致：

| 變數 | 用途 |
|------|------|
| `--hermes` / `--accent` | 該頁主題色（按鈕、強調、連結、步驟編號） |
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
