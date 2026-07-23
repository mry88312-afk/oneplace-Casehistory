-- ============================================================
-- LINE 萃取改背景佇列（v2 架構）：上傳=排隊，pg_cron 每分鐘打 edge fn mode=work
-- 修正：案場對應只認 site_no（不做地址比對）
-- 事件加「後續處理 followup / 狀態 status」追蹤欄位（prompt 同步升級：合併流水帳＋案場總結）
-- 本檔與線上一致（已 apply：line_ingest_queue）
-- ============================================================

alter table property.property_line_events add column if not exists followup text;
alter table property.property_line_events add column if not exists status text;

create table if not exists property.line_ingest_jobs (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references property.properties(id) on delete cascade,
  site_no text,
  source_file text not null,
  transcript text not null,
  force boolean not null default false,
  status text not null default 'pending',   -- pending / processing / done / error
  error text,
  extracted int,
  inserted int,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);
create index if not exists idx_line_jobs_status on property.line_ingest_jobs(status, created_at);

-- resolve：只認案場編號
drop function if exists public.dashboard_resolve_property(text, text);
drop function if exists public.dashboard_resolve_property(text, text, text);
create function public.dashboard_resolve_property(p_site_no text, p_source_file text default null)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce((
    select jsonb_build_object(
             'id', p.id, 'site_no', p.site_no,
             'name', coalesce(nullif(p.short_name,''), p.site_no),
             'existing_count',
               case when p_source_file is null then 0 else
                 (select count(*) from property.property_line_events le
                   where le.property_id = p.id and le.source_file = p_source_file) end)
      from property.properties p
     where p.site_no = p_site_no
     limit 1
  ), '{}'::jsonb);
$fn$;

-- enqueue：排隊（重複檔跳過、已在佇列不重複排）
create or replace function public.dashboard_line_enqueue(
  p_site_no text, p_source_file text, p_transcript text, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_pid uuid; v_name text; v_existing int; v_job uuid;
begin
  select p.id, coalesce(nullif(p.short_name,''), p.site_no) into v_pid, v_name
    from property.properties p where p.site_no = p_site_no limit 1;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error', '找不到案場編號 '||coalesce(p_site_no,'(空)'));
  end if;

  select count(*) into v_existing from property.property_line_events
   where property_id = v_pid and source_file = p_source_file;
  if v_existing > 0 and not p_force then
    return jsonb_build_object('ok', true, 'skipped', true, 'existing', v_existing,
                              'site_no', p_site_no, 'name', v_name);
  end if;

  select id into v_job from property.line_ingest_jobs
   where property_id = v_pid and source_file = p_source_file
     and status in ('pending','processing') limit 1;
  if v_job is not null then
    return jsonb_build_object('ok', true, 'queued', true, 'already_queued', true,
                              'job_id', v_job, 'site_no', p_site_no, 'name', v_name);
  end if;

  if p_transcript is null or length(trim(p_transcript)) < 20 then
    return jsonb_build_object('ok', false, 'error', '對話內容太短或空白');
  end if;

  insert into property.line_ingest_jobs (property_id, site_no, source_file, transcript, force)
  values (v_pid, p_site_no, p_source_file, p_transcript, p_force)
  returning id into v_job;
  return jsonb_build_object('ok', true, 'queued', true, 'job_id', v_job,
                            'existing', v_existing, 'site_no', p_site_no, 'name', v_name);
end $fn$;

-- worker 取件（原子性，skip locked）
create or replace function public.dashboard_line_claim_jobs(p_limit int default 2)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v jsonb;
begin
  with c as (
    select id from property.line_ingest_jobs
     where status = 'pending' order by created_at
     limit greatest(p_limit,1) for update skip locked
  ), u as (
    update property.line_ingest_jobs j
       set status = 'processing', started_at = now()
      from c where j.id = c.id
    returning j.id, j.property_id, j.source_file, j.transcript
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'property_id', property_id,
           'source_file', source_file, 'transcript', transcript)), '[]'::jsonb)
    into v from u;
  return v;
end $fn$;

-- worker 回報結果（done 時清 transcript 減肥）
create or replace function public.dashboard_line_finish_job(
  p_job_id uuid, p_status text, p_error text default null,
  p_extracted int default null, p_inserted int default null)
returns void language sql security definer set search_path=public as $fn$
  update property.line_ingest_jobs
     set status = p_status, error = p_error,
         extracted = p_extracted, inserted = p_inserted,
         finished_at = now(),
         transcript = case when p_status = 'done' then '' else transcript end
   where id = p_job_id;
$fn$;

-- 佇列狀態（上傳頁輪詢用，不含 transcript）
create or replace function public.dashboard_line_jobs_status(p_limit int default 60)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'job_id', j.id, 'site_no', j.site_no,
      'name', coalesce(nullif(p.short_name,''), p.site_no),
      'source_file', j.source_file, 'status', j.status, 'error', j.error,
      'extracted', j.extracted, 'inserted', j.inserted,
      'created_at', to_char(j.created_at at time zone 'Asia/Taipei','YYYY-MM-DD HH24:MI'),
      'finished_at', to_char(j.finished_at at time zone 'Asia/Taipei','HH24:MI')) x
    from property.line_ingest_jobs j
    join property.properties p on p.id = j.property_id
    order by j.created_at desc limit greatest(p_limit,1)
  ) s;
$fn$;

-- upsert 支援 followup / status
create or replace function public.dashboard_line_upsert(p_property_id uuid, p_source_file text, p_events jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_count int;
begin
  delete from property.property_line_events
   where property_id = p_property_id and source_file = p_source_file;
  insert into property.property_line_events
    (property_id, event_date, subcat, title, description, followup, status, speaker_role, source_file)
  select p_property_id,
         (e->>'date')::date,
         nullif(e->>'subcat',''),
         left(e->>'title', 200),
         nullif(e->>'desc',''),
         nullif(e->>'followup',''),
         nullif(e->>'status',''),
         nullif(e->>'speaker',''),
         p_source_file
    from jsonb_array_elements(p_events) e
   where e->>'date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     and coalesce(trim(e->>'title'),'') <> '';
  get diagnostics v_count = row_count;
  return jsonb_build_object('inserted', v_count);
end $fn$;

-- 權限：全部只給 service_role（頁面一律經 edge function）
revoke all on function public.dashboard_resolve_property(text, text) from public, anon;
revoke all on function public.dashboard_line_enqueue(text, text, text, boolean) from public, anon;
revoke all on function public.dashboard_line_claim_jobs(int) from public, anon;
revoke all on function public.dashboard_line_finish_job(uuid, text, text, int, int) from public, anon;
revoke all on function public.dashboard_line_jobs_status(int) from public, anon;
revoke all on function public.dashboard_line_upsert(uuid, text, jsonb) from public, anon;
grant execute on function public.dashboard_resolve_property(text, text) to service_role;
grant execute on function public.dashboard_line_enqueue(text, text, text, boolean) to service_role;
grant execute on function public.dashboard_line_claim_jobs(int) to service_role;
grant execute on function public.dashboard_line_finish_job(uuid, text, text, int, int) to service_role;
grant execute on function public.dashboard_line_jobs_status(int) to service_role;
grant execute on function public.dashboard_line_upsert(uuid, text, jsonb) to service_role;

-- pg_cron：每分鐘驅動 worker
do $$
begin
  if exists (select 1 from cron.job where jobname = 'line-extract-worker') then
    perform cron.unschedule('line-extract-worker');
  end if;
end $$;
select cron.schedule('line-extract-worker', '* * * * *', $cron$
  select net.http_post(
    url := 'https://dwoahbduwzfzqmwpvadj.supabase.co/functions/v1/line-extract',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object('mode','work')
  );
$cron$);
