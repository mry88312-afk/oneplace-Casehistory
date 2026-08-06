-- ============================================================
-- site-management LINE 月結摘要
-- 來源原文保留在 site-management.chatMessages；Supabase 僅保存摘要成果與執行紀錄。
-- 同案場同月份可安全重跑：該月份事件整批覆蓋，既有滾動總結只在成功 commit 時更新。
-- ============================================================

alter table property.property_line_events
  add column if not exists source_kind text not null default 'line_export',
  add column if not exists source_period_start date,
  add column if not exists source_period_end date,
  add column if not exists source_key text,
  add column if not exists ai_model text,
  add column if not exists generated_at timestamptz;

create unique index if not exists uq_line_events_property_source_key
  on property.property_line_events(property_id, source_key)
  where source_key is not null;

create index if not exists idx_line_events_monthly_period
  on property.property_line_events(property_id, source_kind, source_period_start, source_period_end);

create table if not exists property.property_line_rollups (
  property_id uuid primary key references property.properties(id) on delete cascade,
  summary text not null,
  completed_items jsonb not null default '[]'::jsonb,
  tracking_items jsonb not null default '[]'::jsonb,
  unresolved_items jsonb not null default '[]'::jsonb,
  source_period_start date not null,
  source_period_end date not null,
  ai_model text,
  generated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint property_line_rollups_arrays check (
    jsonb_typeof(completed_items) = 'array'
    and jsonb_typeof(tracking_items) = 'array'
    and jsonb_typeof(unresolved_items) = 'array'
  )
);

create table if not exists property.line_monthly_summary_runs (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references property.properties(id) on delete cascade,
  site_no text not null,
  period_start date not null,
  period_end date not null,
  status text not null default 'running',
  attempt_count int not null default 1,
  message_count int,
  event_count int,
  ai_model text,
  error text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint line_monthly_summary_runs_period check (period_end >= period_start),
  constraint line_monthly_summary_runs_status check (status in ('running','success','failed')),
  unique(property_id, period_start, period_end)
);

create index if not exists idx_line_monthly_summary_runs_recent
  on property.line_monthly_summary_runs(created_at desc);

create or replace function public.dashboard_line_monthly_prepare(
  p_site_no text,
  p_period_start date,
  p_period_end date,
  p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare
  v_pid uuid;
  v_property_count int;
  v_run property.line_monthly_summary_runs%rowtype;
  v_run_id uuid;
  v_rollup jsonb;
  v_open_events jsonb;
begin
  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then
    return jsonb_build_object('ok', false, 'error', '摘要月份區間不正確');
  end if;

  select count(*) into v_property_count
    from property.properties p where p.site_no = trim(p_site_no);
  if v_property_count <> 1 then
    return jsonb_build_object(
      'ok', false,
      'error', case when v_property_count = 0
        then 'Supabase 找不到案場編號 '||coalesce(trim(p_site_no),'(空)')
        else 'Supabase 案場編號不唯一 '||coalesce(trim(p_site_no),'(空)') end,
      'matches', v_property_count);
  end if;

  select p.id into v_pid from property.properties p where p.site_no = trim(p_site_no);

  select * into v_run
    from property.line_monthly_summary_runs r
   where r.property_id = v_pid
     and r.period_start = p_period_start
     and r.period_end = p_period_end
   for update;

  if found and v_run.status = 'running'
     and v_run.started_at > now() - interval '2 hours' then
    return jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'already_running',
      'run_id', v_run.id,
      'property_id', v_pid,
      'site_no', trim(p_site_no));
  end if;

  if found and not p_force and v_run.status = 'success' then
    return jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'already_success',
      'run_id', v_run.id,
      'property_id', v_pid,
      'site_no', trim(p_site_no));
  end if;

  if found then
    update property.line_monthly_summary_runs
       set status = 'running', attempt_count = attempt_count + 1,
           message_count = null, event_count = null, ai_model = null,
           error = null, started_at = now(), finished_at = null, updated_at = now()
     where id = v_run.id
     returning id into v_run_id;
  else
    insert into property.line_monthly_summary_runs
      (property_id, site_no, period_start, period_end)
    values (v_pid, trim(p_site_no), p_period_start, p_period_end)
    returning id into v_run_id;
  end if;

  select jsonb_build_object(
      'summary', r.summary,
      'completed_items', r.completed_items,
      'tracking_items', r.tracking_items,
      'unresolved_items', r.unresolved_items,
      'source_period_start', r.source_period_start,
      'source_period_end', r.source_period_end)
    into v_rollup
    from property.property_line_rollups r where r.property_id = v_pid;

  select coalesce(jsonb_agg(jsonb_build_object(
      'source_key', e.source_key,
      'date', to_char(e.event_date,'YYYY-MM-DD'),
      'subcat', e.subcat,
      'title', e.title,
      'description', e.description,
      'followup', e.followup,
      'status', e.status)
      order by e.event_date, e.created_at), '[]'::jsonb)
    into v_open_events
    from property.property_line_events e
   where e.property_id = v_pid
     and e.source_key is not null
     and e.status in ('追蹤中','未解決');

  return jsonb_build_object(
    'ok', true,
    'run_id', v_run_id,
    'property_id', v_pid,
    'site_no', trim(p_site_no),
    'current_rollup', v_rollup,
    'open_events', v_open_events);
end $fn$;

create or replace function public.dashboard_line_monthly_commit(
  p_run_id uuid,
  p_site_no text,
  p_period_start date,
  p_period_end date,
  p_ai_model text,
  p_message_count int,
  p_events jsonb,
  p_event_updates jsonb,
  p_rollup jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare
  v_run property.line_monthly_summary_runs%rowtype;
  v_inserted int := 0;
  v_updated int := 0;
begin
  select * into v_run
    from property.line_monthly_summary_runs r
   where r.id = p_run_id
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', '找不到摘要執行紀錄');
  end if;
  if v_run.site_no <> trim(p_site_no)
     or v_run.period_start <> p_period_start
     or v_run.period_end <> p_period_end then
    return jsonb_build_object('ok', false, 'error', '摘要執行紀錄與案場月份不符');
  end if;
  if jsonb_typeof(coalesce(p_events, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_event_updates, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_rollup, '{}'::jsonb)) <> 'object'
     or coalesce(trim(p_rollup->>'summary'),'') = '' then
    return jsonb_build_object('ok', false, 'error', 'AI 摘要格式不正確');
  end if;

  delete from property.property_line_events e
   where e.property_id = v_run.property_id
     and e.source_kind = 'site_management_monthly'
     and e.source_period_start = p_period_start
     and e.source_period_end = p_period_end;

  insert into property.property_line_events
    (property_id, event_date, subcat, title, description, followup, status,
     speaker_role, source_file, source_kind, source_period_start, source_period_end,
     source_key, ai_model, generated_at)
  select distinct on (trim(e->>'event_key'))
         v_run.property_id,
         (e->>'date')::date,
         nullif(e->>'subcat',''),
         left(trim(e->>'title'), 200),
         nullif(trim(e->>'desc'),''),
         nullif(trim(e->>'followup'),''),
         case when e->>'status' in ('已完成','追蹤中','未解決','資訊') then e->>'status' else '資訊' end,
         nullif(trim(e->>'speaker'),''),
         'site-management:'||to_char(p_period_start,'YYYY-MM'),
         'site_management_monthly',
         p_period_start,
         p_period_end,
         'site-management:'||to_char(p_period_start,'YYYY-MM')||':'||left(trim(e->>'event_key'), 120),
         nullif(trim(p_ai_model),''),
         now()
    from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) e
   where e->>'date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     and e->>'date' between to_char(p_period_start, 'YYYY-MM-DD') and to_char(p_period_end, 'YYYY-MM-DD')
     and coalesce(trim(e->>'title'),'') <> ''
     and coalesce(trim(e->>'event_key'),'') <> ''
   order by trim(e->>'event_key');
  get diagnostics v_inserted = row_count;

  with updates as (
    select distinct on (trim(item.value->>'source_key')) item.value
      from jsonb_array_elements(coalesce(p_event_updates, '[]'::jsonb)) as item(value)
     where coalesce(trim(item.value->>'source_key'),'') <> ''
     order by trim(item.value->>'source_key')
  )
  update property.property_line_events e
     set followup = coalesce(nullif(trim(updates.value->>'followup'),''), e.followup),
         status = case when updates.value->>'status' in ('已完成','追蹤中','未解決','資訊')
                       then updates.value->>'status' else e.status end,
         ai_model = nullif(trim(p_ai_model),''),
         generated_at = now()
    from updates
   where e.property_id = v_run.property_id
     and e.source_key = trim(updates.value->>'source_key')
     and e.source_kind = 'site_management_monthly';
  get diagnostics v_updated = row_count;

  insert into property.property_line_rollups
    (property_id, summary, completed_items, tracking_items, unresolved_items,
     source_period_start, source_period_end, ai_model, generated_at, updated_at)
  values (
    v_run.property_id,
    trim(p_rollup->>'summary'),
    case when jsonb_typeof(p_rollup->'completed_items') = 'array' then p_rollup->'completed_items' else '[]'::jsonb end,
    case when jsonb_typeof(p_rollup->'tracking_items') = 'array' then p_rollup->'tracking_items' else '[]'::jsonb end,
    case when jsonb_typeof(p_rollup->'unresolved_items') = 'array' then p_rollup->'unresolved_items' else '[]'::jsonb end,
    p_period_start, p_period_end, nullif(trim(p_ai_model),''), now(), now())
  on conflict (property_id) do update set
    summary = excluded.summary,
    completed_items = excluded.completed_items,
    tracking_items = excluded.tracking_items,
    unresolved_items = excluded.unresolved_items,
    source_period_start = excluded.source_period_start,
    source_period_end = excluded.source_period_end,
    ai_model = excluded.ai_model,
    generated_at = excluded.generated_at,
    updated_at = now();

  update property.line_monthly_summary_runs
     set status = 'success', message_count = greatest(coalesce(p_message_count,0),0),
         event_count = v_inserted, ai_model = nullif(trim(p_ai_model),''),
         error = null, finished_at = now(), updated_at = now()
   where id = p_run_id;

  return jsonb_build_object('ok', true, 'inserted', v_inserted, 'updated', v_updated);
end $fn$;

create or replace function public.dashboard_line_monthly_fail(
  p_run_id uuid,
  p_error text)
returns void language sql security definer set search_path=public as $fn$
  update property.line_monthly_summary_runs
     set status = 'failed', error = left(coalesce(p_error,'未知錯誤'),1000),
         finished_at = now(), updated_at = now()
   where id = p_run_id;
$fn$;

create or replace function public.dashboard_line_monthly_runs(p_limit int default 50)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id,
      'site_no', r.site_no,
      'name', coalesce(nullif(p.short_name,''), p.site_no),
      'period_start', to_char(r.period_start,'YYYY-MM-DD'),
      'period_end', to_char(r.period_end,'YYYY-MM-DD'),
      'status', r.status,
      'attempt_count', r.attempt_count,
      'message_count', r.message_count,
      'event_count', r.event_count,
      'ai_model', r.ai_model,
      'error', r.error,
      'started_at', r.started_at,
      'finished_at', r.finished_at)
      order by r.created_at desc), '[]'::jsonb)
    from (
      select * from property.line_monthly_summary_runs
       order by created_at desc limit greatest(least(p_limit,200),1)
    ) r
    join property.properties p on p.id = r.property_id;
$fn$;

create or replace function public.dashboard_line_rollup(p_property_id uuid)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce((
    select jsonb_build_object(
      'summary', r.summary,
      'completed_items', r.completed_items,
      'tracking_items', r.tracking_items,
      'unresolved_items', r.unresolved_items,
      'source_period_start', to_char(r.source_period_start,'YYYY-MM-DD'),
      'source_period_end', to_char(r.source_period_end,'YYYY-MM-DD'),
      'ai_model', r.ai_model,
      'generated_at', r.generated_at)
      from property.property_line_rollups r where r.property_id = p_property_id
  ), '{}'::jsonb);
$fn$;

revoke all on function public.dashboard_line_monthly_prepare(text,date,date,boolean) from public, anon, authenticated;
revoke all on function public.dashboard_line_monthly_commit(uuid,text,date,date,text,int,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.dashboard_line_monthly_fail(uuid,text) from public, anon, authenticated;
revoke all on function public.dashboard_line_monthly_runs(int) from public, anon, authenticated;
grant execute on function public.dashboard_line_monthly_prepare(text,date,date,boolean) to service_role;
grant execute on function public.dashboard_line_monthly_commit(uuid,text,date,date,text,int,jsonb,jsonb,jsonb) to service_role;
grant execute on function public.dashboard_line_monthly_fail(uuid,text) to service_role;
grant execute on function public.dashboard_line_monthly_runs(int) to service_role;

revoke all on function public.dashboard_line_rollup(uuid) from public;
grant execute on function public.dashboard_line_rollup(uuid) to anon, authenticated, service_role;

comment on table property.property_line_rollups is 'site-management 每月 AI 產生的案場 LINE 滾動總結';
comment on table property.line_monthly_summary_runs is 'site-management LINE 月結摘要執行與冪等紀錄';
