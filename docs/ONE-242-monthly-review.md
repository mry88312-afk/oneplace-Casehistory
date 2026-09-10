# ONE-242 月結版本及發布規則

業務決策：使用者於 2026-09-10 確認「保留舊版，新版人工確認後才發布」。

## 狀態與資料

- `prepare` 每次取得獨立版本 UUID；`commit` 只存 `pending_review`，不碰已發布事件或總結。
- 每版保留 payload 與產生當下的已發布資料快照（含導入版本機制前的舊資料）。既有版本不可被重跑覆寫。
- `publish` 須經 site-management 內部可編輯員工的登入 API；操作者由 server session 產生，不能由瀏覽器指定。
- 發布前再次核對已發布快照；有其他版本發布或人工更新時，拒絕過期草稿，須重新產生。
- 已有較新月份總結時，舊月份版本只能查閱，禁止發布倒退。
- 發布以交易更新既有投影表；舊投影已保留於快照，歷次 AI payload 持續保存。
- IAM 仍使用 `dashboard_timeline_events` / `dashboard_line_rollup`，不讀未發布版本。
- 產生端僅取上月補跑；每月 1 日 03:00 起每日補查，不掃描更早歷史月份。成功／待確認跳過，失敗有 24 小時冷卻；手動重跑可明確繞過冷卻。
- 排程補跑依賴服務啟用 `CASE_HISTORY_MONTHLY_ENABLED=true`；不是獨立雲端排程。長時間離線超過一個月份的歷史補跑仍需手動指定。

## 交付及部署順序

1. 正式 Supabase 專案為 `dwoahbduwzfzqmwpvadj`，不可套用 IAM PostgreSQL。
2. migration：`supabase/migrations/20260910174000_monthly_review_versions.sql`。本次已透過 MCP 套正式庫；不要重跑 rename 操作。
3. 部署 `supabase/functions/case-history-monthly/index.ts`，沿用 `x-case-history-secret` 自訂驗證和原本 `verify_jwt=false`，增加 `versions` / `publish` 轉送。
4. site-management 對應 PR 基於 `origin/main`。正式環境追蹤 `zeabur-main`，兩者存在分歧；需要將本票 commit 單獨整合到最新正式分支並開 PR，不可直接 merge 兩條主線。
5. 部署 site-management 後，`/case-history-summary` 展開案場，查閱版本與既有發布快照，再按「確認並發布此版」。
6. 由使用者更新正式 `OPENAI_API_KEY`，服務載入新值後，只選一個已授權案場／月份產生新版，確認事件／總結，再發布及回讀。
7. 最後在 `https://iamportal.zeabur.app/dashboard?view=case-history` 登入驗證同一案場。不能將 DB 成功當作畫面驗收。

## 驗證

本機 `npm ci` 後 `npm test`：11 項 SQL 整合測試，使用隔離記憶體 PostgreSQL（PGlite），不寫正式業務資料。
涵蓋草稿隔離、版本保留、公開權限拒絕、發布操作者、過期草稿、過期 worker、失敗保護、日期與重複事件、舊月份保護、IAM rollup 讀取介面。
這不取代真實 PostgreSQL 多連線壓力測試或登入後畫面驗證。

2026-09-10 正式 migration 前後比對：

| 資料 | 筆數 | 前後相同的內容校驗值 |
|---|---:|---|
| property_line_events | 5552 | eb5219f01be5652b72b784e40a4916ed |
| property_line_rollups | 122 | 13762298e7a0ab3b522d31efc76e9cff |

## 回滾／失敗處理

- 勿復原「自動刪除並覆蓋當月事件」的舊 commit RPC。保留版本表及已存快照。
- 應用程式需回退時，可先停用月結入口／`CASE_HISTORY_MONTHLY_ENABLED`；資料庫繼續將生成結果保存為待確認，避免恢復自動發布。
- 不可刪除新版本資料或自動發布補救。若要恢復歷史發布內容，先列具體案場／版本與資料差異，另取得批准。
- migration 套用到前端上線之間，舊 UI 可能把成功生成顯示為成功但回讀未通過；資料實際為待確認，尚未發布。新 UI 上線後才能人工發布。
- 沒有刪除任何 repository 檔案。
