// LINE 對話萃取 edge function（v4，與線上部署一致）
// 背景佇列架構：頁面只做 enqueue/check/status；真正萃取由 pg_cron 每分鐘
// 打 mode=work 驅動（cron job: line-extract-worker），關掉網頁也會繼續處理。
// 無密碼；案場對應只認檔名開頭的 site_no；模型 claude-opus-4-8。
// modes:
//  - check   {site_no, source_file}                 → 是否已傳過（前端預檢）
//  - enqueue {site_no, source_file, transcript, force} → 排隊（重複檔跳過；force 覆蓋重萃）
//  - status  {}                                     → 最近佇列狀態（進度看板輪詢）
//  - work    {}                                     → 取件並萃取入庫（cron 專用）
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") || "";
const MODEL = "claude-opus-4-8";

const SYSTEM_PROMPT = `你是「一方生活」包租代管公司的營運分析師。使用者會給你某個案場的 LINE 群組對話記錄（用於開發洽談、裝修工務、驗收、營運溝通）。
請先完整讀完全部對話再開始萃取，用 submit_events 工具輸出。

【核心要求：不只直述，要追蹤結局】
每個事件除了發生當下，還要往對話後面追蹤它的下文：
- followup：後續怎麼處理、誰處理、何時完成（從後面的對話找結果，例：「9/13 工務完成 3/4/9/10 項，9/15 全數修畢」）
- status：已完成（對話中看得到結果）/ 追蹤中（有後續但未結案）/ 未解決（到對話結束都沒下文）/ 資訊（單純資訊性質無需追蹤）
同一件事的發生→處理→完成合併成一筆事件（日期用發生日），不要拆成多筆流水帳。

【案場總結（必要，恰好一筆）】
最後加一筆 subcat=總結的事件：date 用對話最後一天，title 「案場LINE總結」，
desc 用 3~5 句概括整個歷程（開發背景與補助→裝修重點與金額→上線狀態→房東關係），
followup 列出「到對話結束仍未解決或懸而未決的事項清單」（沒有就寫無），status 用資訊。

【要萃取（subcat 分類）】
- 洽談：房東/屋主出價、裝修補助金額、租金條件、房東態度回饋、回訪
- 房況：格局、採光、可隔間數、既有問題（壁紙、漏水史、頂樓加蓋、共用電）
- 工務：進場、油漆、軟裝、燈具、缺失清單、修繕進度、驗收檢核、收尾
- 定價：各房型定價與最終定案（有多版本時合併一筆，初版寫在 desc、定案寫在 followup）
- 排程：拍攝、看房、安裝、施工排程（改期合併成一筆）
- 異常：漏水、鄰損糾紛、電力不足、缺料等問題及處理指派（followup 必填追蹤結果）
- 里程碑：案場開發啟動、房東回訪滿意、案場完工收尾等重大節點
- 額外有價值的資訊也要收：頂樓/鄰居/共用設施狀況、特殊條件、未來可能的機會 → 歸入最接近的分類

【忽略雜訊】純「圖片/影片/貼圖」訊息、相簿/記事本系統訊息、成員加退群、設定公告、已收回訊息、純招呼確認。

【隱私規則（務必遵守）】
- 不萃取任何個資：身分證號、電話、銀行帳號、私人住址、Email
- 人物一律用角色代稱（房東、屋主弟弟、租客、開發、服務部、設計、工務、房仲、主管），不寫全名
- 索取「屋主身分證/電費單/電話」只記「已向屋主索取文件」，不記內容
- 金額、房型代號、坪數、缺失項目等營運數據要保留

【格式】日期以對話日期分隔行（YYYY.MM.DD 星期X）為準。title 15 字內；desc 1~2 句含關鍵數字；依日期由舊到新。寧精勿濫：一般案場 15~30 筆內。`;

const SUBMIT_TOOL = {
  name: "submit_events",
  description: "提交萃取出的營運事件清單（含最後一筆總結）",
  input_schema: {
    type: "object",
    properties: {
      events: {
        type: "array",
        items: {
          type: "object",
          properties: {
            date: { type: "string", description: "YYYY-MM-DD" },
            subcat: { type: "string", enum: ["洽談", "房況", "工務", "定價", "排程", "異常", "里程碑", "總結"] },
            title: { type: "string", description: "15 字內" },
            desc: { type: "string", description: "發生當下的摘要 1~2 句" },
            followup: { type: "string", description: "後續處理與結果；無後續留空" },
            status: { type: "string", enum: ["已完成", "追蹤中", "未解決", "資訊"] },
            speaker: { type: "string", description: "發言角色，非全名" },
          },
          required: ["date", "title", "status"],
        },
      },
    },
    required: ["events"],
  },
};

async function rpc(fn: string, args: unknown) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`${fn} ${res.status}: ${(await res.text()).substring(0, 300)}`);
  const t = await res.text();
  return t ? JSON.parse(t) : null;   // void RPC 回 204 空 body
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "content-type": "application/json" } });
}

async function extractOne(job: any) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model: MODEL, max_tokens: 16000, system: SYSTEM_PROMPT,
      tools: [SUBMIT_TOOL], tool_choice: { type: "tool", name: "submit_events" },
      messages: [{ role: "user", content: "以下是對話記錄，請萃取：\n\n" + job.transcript.substring(0, 300000) }],
    }),
  });
  if (!res.ok) { const t = await res.text(); throw new Error(`Claude API ${res.status}: ${t.substring(0, 300)}`); }
  const j = await res.json();
  const tu = (j.content || []).find((b: any) => b.type === "tool_use");
  return tu?.input?.events || [];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }
  const { mode = "enqueue", site_no = null, source_file = "unknown.txt", transcript = "", force = false } = body;

  try {
    if (mode === "check") {
      const r = await rpc("dashboard_resolve_property", { p_site_no: site_no, p_source_file: source_file });
      if (!r || !r.id) return json({ ok: false, error: "找不到案場編號 " + (site_no || "(空)") });
      return json({ ok: true, resolved: r, existing: r.existing_count || 0, will_skip: (r.existing_count || 0) > 0 && !force });
    }

    if (mode === "enqueue") {
      const r = await rpc("dashboard_line_enqueue", { p_site_no: site_no, p_source_file: source_file, p_transcript: transcript, p_force: force });
      return json(r);
    }

    if (mode === "status") {
      const r = await rpc("dashboard_line_jobs_status", { p_limit: 80 });
      return json({ ok: true, jobs: r });
    }

    if (mode === "work") {
      if (!ANTHROPIC_API_KEY) return json({ ok: false, error: "ANTHROPIC_API_KEY 未設定" }, 500);
      const jobs = await rpc("dashboard_line_claim_jobs", { p_limit: 2 });
      const results = [];
      for (const job of jobs || []) {
        try {
          const events = await extractOne(job);
          if (!Array.isArray(events) || events.length === 0) {
            await rpc("dashboard_line_finish_job", { p_job_id: job.id, p_status: "error", p_error: "未萃取到任何事件", p_extracted: 0, p_inserted: 0 });
            results.push({ id: job.id, ok: false, error: "no events" });
            continue;
          }
          const up = await rpc("dashboard_line_upsert", { p_property_id: job.property_id, p_source_file: job.source_file, p_events: events });
          await rpc("dashboard_line_finish_job", { p_job_id: job.id, p_status: "done", p_error: null, p_extracted: events.length, p_inserted: up?.inserted ?? 0 });
          results.push({ id: job.id, ok: true, extracted: events.length, inserted: up?.inserted ?? 0 });
        } catch (e) {
          await rpc("dashboard_line_finish_job", { p_job_id: job.id, p_status: "error", p_error: String((e as Error).message).substring(0, 500), p_extracted: null, p_inserted: null }).catch(() => {});
          results.push({ id: job.id, ok: false, error: String((e as Error).message).substring(0, 200) });
        }
      }
      return json({ ok: true, claimed: (jobs || []).length, results });
    }

    return json({ ok: false, error: "unknown mode" }, 400);
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message).substring(0, 500) }, 500);
  }
});
