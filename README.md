# 一方生活 · 案場歷程（獨立部署）

從主儀表板（`oneplace_dashboard`）**拆出來的「案場歷程」功能**，獨立成一個 repo + 一組 Zeabur 部署。
純靜態 HTML，前端直連既有的 Supabase 專案，**不需要自己的資料庫、不需要自己的後端**。

## 頁面

| 檔案 | 說明 |
|---|---|
| `public/index.html` | 導向頁（案場歷程 / 上傳 LINE） |
| `public/case-history.html` | 案場歷程時間軸（含 LINE 對話摘要、覆蓋率、尚缺清單） |
| `public/line-upload.html` | LINE 對話上傳（**只存檔、不跑 AI**；案場層級去重；覆蓋率/尚缺清單） |

---

## 🔑 環境變數盤點（重點）

### Zeabur（這個新專案）→ **不需要任何環境變數**

- Supabase 的 **URL 與 anon key 直接寫死在 HTML 裡**（`case-history.html` / `line-upload.html` 開頭的 `SUPABASE_URL` / `SUPABASE_ANON_KEY`）。
- anon key **設計上就是給前端公開用的**，資料安全靠 Supabase 的 RLS + SECURITY DEFINER RPC 控管，放在公開 repo/網頁沒有問題。
- Zeabur 只需要能跑 `npm start`（= `npx serve -s public`）把 `public/` 當靜態站 serve。Zeabur 會自動注入 `$PORT`，start script 已經吃 `${PORT:-3000}`。
- **結論：Zeabur 後台不用填任何環境變數，直接部署即可。**

### Supabase（共用的既有後端，**不在這次搬遷範圍**，這裡只是盤點）

資料與 RPC 都在既有的 Supabase 專案 `dwoahbduwzfzqmwpvadj`，沿用即可、不用動。若之後要重建同一套後端，需要：

Edge Function `line-extract` 的 secrets（設在 **Supabase**，不是 Zeabur）：

| 變數 | 用途 | 現況 |
|---|---|---|
| `SUPABASE_URL` | 讓 edge fn 連自己的 DB | 已設 |
| `SUPABASE_SERVICE_ROLE_KEY` | 呼叫 SECURITY DEFINER RPC（enqueue/status） | 已設 |
| `ANTHROPIC_API_KEY` | 只有 AI `work` 模式才用 | 已設但**目前用不到**（上傳只存檔，不跑 AI；額度也已用完） |

> 目前的萃取流程：上傳頁只做 enqueue 存原始檔；真正的 AI 萃取改由本機（Claude Code）批次跑，不靠 edge fn 的 `work` 模式，`pg_cron` 的 `line-extract-worker` 已停用。

---

## 後端相依（都在共用 Supabase，已部署，這裡的檔案僅供參考／版本紀錄）

- `supabase/functions/line-extract/index.ts` — 上傳頁呼叫的 edge function（enqueue / status / check / work）
- `supabase/migrations/*.sql` — 相關資料表與 RPC：
  - `property_line_events`（LINE 事件表）、`line_ingest_jobs`（上傳佇列）
  - RPC：`dashboard_timeline_properties`（含 `has_upload` / `has_line`）、`dashboard_timeline_events`、`dashboard_line_enqueue`（案場層級去重）、`dashboard_line_jobs_status`、`dashboard_line_upsert` 等

> ⚠️ 這些 migration **已套用在共用 Supabase**，沿用同一個專案時**不要重跑**。只有在另建一個全新的 Supabase 專案時才需要依序執行。

---

## 本機預覽

```bash
npm run dev      # → http://localhost:3000
```

## Zeabur 部署

1. Zeabur → New Project → 綁這個 GitHub repo（`main` 分支）。
2. 服務類型走 Node（會自動偵測 `package.json` + `zbpack.json`，`npm start` serve `public/`）。
3. 環境變數：**留空即可**（見上）。
4. 部署完成後綁自訂網域或用 Zeabur 給的網址，把 `line-upload.html` 丟給同事上傳。
