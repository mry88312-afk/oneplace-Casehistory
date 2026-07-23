-- 保留原始對話：job 標記 done 時不再清空 transcript（原本會設為 ''）。
-- 目的：日後萃取品質不佳可直接重跑，不需請同事重傳。transcript 很小（KB 級），對 DB 無負擔。
-- 本檔與線上一致（已 apply：line_finish_keep_transcript）
create or replace function public.dashboard_line_finish_job(
  p_job_id uuid, p_status text, p_error text default null,
  p_extracted int default null, p_inserted int default null)
returns void language sql security definer set search_path=public as $fn$
  update property.line_ingest_jobs
     set status = p_status, error = p_error,
         extracted = p_extracted, inserted = p_inserted,
         finished_at = now()
   where id = p_job_id;
$fn$;
