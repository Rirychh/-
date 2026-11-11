# Claude 多帳號工具（Windows）

在同一台 Windows 電腦上同時開兩個以上的 Claude 帳號。每個帳號有自己的桌面捷徑、登入狀態和本機資料，互不干擾。免費，不用安裝其他軟體。

## 兩種模式

| 模式 | 開出來的是 | 優點 | 缺點 |
|------|-----------|------|------|
| **desktop** | 官方 Claude 桌面版 | 有 Claude Code、Cowork、MCP 等桌面版功能 | 依賴 Claude 桌面版支援獨立資料夾；Microsoft Store 版不能用 |
| **web** | Edge／Chrome 的 claude.ai 獨立視窗 | 最穩定，一定能用 | 沒有桌面版專屬功能 |

你原本的 Claude 桌面版就是第一個帳號，維持不動。這個工具是用來新增「第二個、第三個」帳號。

## 安裝

1. 下載這個資料夾裡的 `ClaudeMulti.ps1` 和 `ClaudeMulti.bat`，放在同一個資料夾
2. 雙擊 `ClaudeMulti.bat`
3. 如果 Windows 跳出「Windows 已保護您的電腦」，按「其他資訊」→「仍要執行」

第一次執行時，工具會把自己複製到 `%LOCALAPPDATA%\ClaudeMulti`。之後桌面捷徑都指向那裡，所以下載的檔案可以刪掉。

## 使用步驟

1. 雙擊 `ClaudeMulti.bat`，選 **1. 新增帳號**
2. 輸入代號（例如 `work`）和備註
3. 選模式：建議先用 **1 (desktop)**
4. 選擇建立桌面捷徑
5. 選擇現在登入：工具會開一個新的 Claude 視窗，在裡面登入第二個帳號
6. 瀏覽器問「要開啟 Claude 嗎？」時按「開啟」，登入完成後回到工具視窗按 Enter

之後點桌面上的「Claude - work」捷徑，就會直接開第二個帳號。原本的 Claude 圖示還是第一個帳號，兩個可以同時開著。

## 如果 desktop 模式不能用

第一次開啟時，工具會檢查 Claude 有沒有使用獨立資料夾：

- 顯示「確認成功」：可以正常使用
- 顯示「警告：資料夾還是空的」：代表這個版本的 Claude 不支援獨立資料夾。請用選單 **6** 刪掉這個帳號，再用 **1** 重建並選 **web** 模式

如果登入後跑回第一個帳號，或登入卡住，用選單 **3. 重新登入帳號** 再試一次。

## 運作原理（給想了解的人）

- **desktop 模式**：用 `--user-data-dir` 參數開 Claude，讓每個帳號的資料存在 `%LOCALAPPDATA%\ClaudeMulti\profiles\<代號>\data`
- **登入協助**：桌面版登入時，瀏覽器透過 `claude://` 連結把登入結果送回 app，這個連結預設只會送到原本的帳號。登入期間工具會暫時把 `claude://` 指向新帳號（修改 `HKCU\Software\Classes\claude`，不需要系統管理員權限），按 Enter 後就改回原狀。如果中途關掉視窗，下次打開選單時會自動還原
- **web 模式**：用 Edge／Chrome 的 `--user-data-dir` 和 `--app=https://claude.ai` 開一個獨立的瀏覽器設定檔

## 移除

1. 用選單 **6** 刪除每個額外帳號（只刪本機資料，雲端對話不受影響）
2. 刪除 `%LOCALAPPDATA%\ClaudeMulti` 資料夾

## 注意事項

- 這不是 Anthropic 官方工具，Claude 更新後 desktop 模式有可能失效，那時改用 web 模式即可
- 這個工具不會讀取或儲存你的密碼，登入都在 Claude 自己的視窗裡完成
- 使用多個帳號請遵守 Anthropic 的使用條款
