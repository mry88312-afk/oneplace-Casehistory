-- ONE-242: generation only saves a version; publication requires a trusted server actor.
-- The published projection remains compatible with IAM's existing read RPCs.
create table property.line_monthly_summary_versions (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references property.line_monthly_summary_runs(id),
  property_id uuid not null references property.properties(id),
  site_no text not null,
  period_start date not null,
  period_end date not null,
  version int not null,
  status text not null check (status in ('running','pending_review','published','failed')),
  base_snapshot jsonb not null,
  payload jsonb,
  ai_model text,
  message_count int,
  error text,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  published_by text,
  unique(run_id, version)
);
alter table property.line_monthly_summary_versions enable row level security;
revoke all on property.line_monthly_summary_versions from public, anon, authenticated;
alter table property.line_monthly_summary_runs drop constraint line_monthly_summary_runs_status;
alter table property.line_monthly_summary_runs add constraint line_monthly_summary_runs_status
  check(status in ('running','success','failed','pending_review'));

-- Full published pre-image is retained with every attempt, including pre-versioning data.
create function public.dashboard_line_monthly_snapshot(p_property_id uuid)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select jsonb_build_object(
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id)
      from property.property_line_events e where e.property_id=p_property_id), '[]'::jsonb),
    'rollup', (select to_jsonb(r) from property.property_line_rollups r where r.property_id=p_property_id));
$fn$;

alter function public.dashboard_line_monthly_prepare(text,date,date,boolean)
  rename to dashboard_line_monthly_prepare_internal;
alter function public.dashboard_line_monthly_commit(uuid,text,date,date,text,int,jsonb,jsonb,jsonb)
  rename to dashboard_line_monthly_apply_internal;

create function public.dashboard_line_monthly_prepare(
  p_site_no text, p_period_start date, p_period_end date, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_pid uuid; v_result jsonb; v_run uuid; v_version uuid; v_number int; v_prior record;
begin
  -- Serialize even the first insert: a SELECT FOR UPDATE on an absent run cannot do that.
  perform pg_advisory_xact_lock(hashtextextended('monthly:'||coalesce(trim(p_site_no),''),0));
  select id into v_pid from property.properties where site_no=trim(p_site_no);
  if p_period_start is null or p_period_end is null
    or p_period_start<>date_trunc('month',p_period_start)::date
    or p_period_end<>(p_period_start+interval '1 month - 1 day')::date then
    return jsonb_build_object('ok',false,'error','請使用完整月份');
  end if;
  select * into v_prior from property.line_monthly_summary_runs
    where property_id=v_pid and period_start=p_period_start and period_end=p_period_end;
  if not coalesce(p_force,false) and found and (
    v_prior.status='pending_review' or (v_prior.status='failed' and v_prior.started_at>now()-interval '24 hours')) then
    return jsonb_build_object('ok',true,'skipped',true,'reason',
      case when v_prior.status='pending_review' then 'pending_review' else 'retry_cooldown' end);
  end if;
  v_result := public.dashboard_line_monthly_prepare_internal(p_site_no,p_period_start,p_period_end,p_force);
  if v_result->>'ok'<>'true' or v_result->>'skipped'='true' then return v_result; end if;
  v_run := (v_result->>'run_id')::uuid;
  select attempt_count into v_number from property.line_monthly_summary_runs where id=v_run;
  -- Expired workers cannot later commit over a newer attempt.
  update property.line_monthly_summary_versions set status='failed',error='執行逾時，已建立新版本'
    where run_id=v_run and status='running';
  insert into property.line_monthly_summary_versions
    (run_id,property_id,site_no,period_start,period_end,version,status,base_snapshot)
  values(v_run,(v_result->>'property_id')::uuid,trim(p_site_no),p_period_start,p_period_end,v_number,
    'running',public.dashboard_line_monthly_snapshot((v_result->>'property_id')::uuid)) returning id into v_version;
  -- Do not feed future or same-month events back into a new extraction as old events.
  return v_result || jsonb_build_object('run_id',v_version,'review_required',true,'open_events',coalesce((
    select jsonb_agg(e) from jsonb_array_elements(v_result->'open_events') e
      where e->>'date'<to_char(p_period_start,'YYYY-MM-DD')), '[]'::jsonb),
    'current_rollup',case when (v_result->'current_rollup'->>'source_period_end')::date<p_period_start
      then v_result->'current_rollup' else 'null'::jsonb end);
end $fn$;

create function public.dashboard_line_monthly_commit(
  p_run_id uuid,p_site_no text,p_period_start date,p_period_end date,p_ai_model text,
  p_message_count int,p_events jsonb,p_event_updates jsonb,p_rollup jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v property.line_monthly_summary_versions%rowtype;
begin
  select * into v from property.line_monthly_summary_versions where id=p_run_id for update;
  if not found then return jsonb_build_object('ok',false,'error','摘要版本不存在，請重新產生'); end if;
  if v.site_no is distinct from trim(p_site_no) or v.period_start is distinct from p_period_start
    or v.period_end is distinct from p_period_end then
    return jsonb_build_object('ok',false,'error','版本與案場月份不符');
  end if;
  if v.status in ('pending_review','published') then
    return jsonb_build_object('ok',true,'status',v.status,'version_id',v.id,'inserted',jsonb_array_length(v.payload->'events'));
  end if;
  if v.status<>'running' then return jsonb_build_object('ok',false,'error','此執行已失效'); end if;
  if jsonb_typeof(p_events) is distinct from 'array' or jsonb_typeof(p_event_updates) is distinct from 'array'
    or jsonb_typeof(p_rollup) is distinct from 'object' or coalesce(trim(p_rollup->>'summary'),'')=''
    or p_message_count is null or p_message_count<0 then
    raise exception 'AI 摘要格式不正確';
  end if;
  if jsonb_array_length(p_events)>100 or jsonb_array_length(p_event_updates)>100
    or jsonb_typeof(p_rollup->'completed_items') is distinct from 'array'
    or jsonb_typeof(p_rollup->'tracking_items') is distinct from 'array'
    or jsonb_typeof(p_rollup->'unresolved_items') is distinct from 'array' then
    raise exception 'AI 摘要格式不正確';
  end if;
  if exists(select 1 from jsonb_array_elements(p_events) e where
    coalesce(trim(e->>'event_key'),'')='' or length(e->>'event_key')>120 or coalesce(trim(e->>'title'),'')=''
    or length(e->>'title')>200 or coalesce(e->>'date','') !~ '^\d{4}-\d{2}-\d{2}$'
    or (e->>'date')::date not between p_period_start and p_period_end
    or coalesce(e->>'status','') not in ('已完成','追蹤中','未解決','資訊'))
    or (select count(distinct trim(e->>'event_key')) from jsonb_array_elements(p_events) e)<>jsonb_array_length(p_events) then
    raise exception 'AI 事件日期、狀態或識別碼不正確';
  end if;
  if exists(select 1 from jsonb_array_elements(p_event_updates) u where
    coalesce(u->>'status','') not in ('已完成','追蹤中','未解決','資訊') or not exists (
      select 1 from jsonb_array_elements(v.base_snapshot->'events') e
      where e->>'source_key'=u->>'source_key' and e->>'source_kind'='site_management_monthly'
        and e->>'event_date'<to_char(p_period_start,'YYYY-MM-DD')
        and e->>'status' in ('追蹤中','未解決'))) then raise exception '舊事件更新不在允許範圍'; end if;
  update property.line_monthly_summary_versions set status='pending_review',
    payload=jsonb_build_object('events',p_events,'event_updates',p_event_updates,'rollup',p_rollup),
    ai_model=p_ai_model,message_count=p_message_count where id=v.id;
  update property.line_monthly_summary_runs set status='pending_review',message_count=p_message_count,
    event_count=jsonb_array_length(p_events),ai_model=p_ai_model,error=null,finished_at=now(),updated_at=now()
    where id=v.run_id and attempt_count=v.version;
  return jsonb_build_object('ok',true,'status','pending_review','version_id',v.id,'inserted',jsonb_array_length(p_events));
end $fn$;

create or replace function public.dashboard_line_monthly_fail(p_run_id uuid,p_error text)
returns void language plpgsql security definer set search_path=public as $fn$
declare v property.line_monthly_summary_versions%rowtype; v_error text;
begin
  v_error := left(regexp_replace(coalesce(p_error,'未知錯誤'),'sk-[A-Za-z0-9_*-]+','[REDACTED]','g'),1000);
  update property.line_monthly_summary_versions set status='failed',error=v_error
    where id=p_run_id and status='running' returning * into v;
  if found then
    update property.line_monthly_summary_runs set status='failed',error=v_error,finished_at=now(),updated_at=now()
      where id=v.run_id and attempt_count=v.version;
  end if;
end $fn$;

create function public.dashboard_line_monthly_versions(p_site_no text,p_period_start date)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce(jsonb_agg((to_jsonb(v)-'base_snapshot') || jsonb_build_object('previous_published',
    jsonb_build_object('rollup',v.base_snapshot->'rollup','events',coalesce((
      select jsonb_agg(e) from jsonb_array_elements(v.base_snapshot->'events') e
      where e->>'source_kind'='site_management_monthly' and e->>'source_period_start'=v.period_start::text
    ),'[]'::jsonb))) order by v.version desc),'[]'::jsonb)
    from property.line_monthly_summary_versions v where site_no=trim(p_site_no) and period_start=p_period_start;
$fn$;

create function public.dashboard_line_monthly_publish(p_version_id uuid,p_site_no text,p_actor text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v property.line_monthly_summary_versions%rowtype; v_result jsonb; v_old_rollup jsonb;
begin
  if coalesce(trim(p_actor),'')='' then return jsonb_build_object('ok',false,'error','缺少登入操作者'); end if;
  perform pg_advisory_xact_lock(hashtextextended('monthly:'||coalesce(trim(p_site_no),''),0));
  select * into v from property.line_monthly_summary_versions where id=p_version_id and site_no=trim(p_site_no) for update;
  if not found then return jsonb_build_object('ok',false,'error','找不到此案場版本'); end if;
  if v.status='published' then return jsonb_build_object('ok',true,'already_published',true); end if;
  if v.status<>'pending_review' then return jsonb_build_object('ok',false,'error','版本尚未完成'); end if;
  -- Block inserts as well as updates from upload/import writers during the short publication.
  -- Row locks alone would miss newly inserted events and absent rollup rows.
  lock table property.property_line_events, property.property_line_rollups in share row exclusive mode;
  if v.base_snapshot is distinct from public.dashboard_line_monthly_snapshot(v.property_id) then
    return jsonb_build_object('ok',false,'error','已發布內容已有更新，請重新產生並確認新版');
  end if;
  select to_jsonb(r) into v_old_rollup from property.property_line_rollups r where property_id=v.property_id;
  if (v_old_rollup->>'source_period_end')::date>v.period_end then
    return jsonb_build_object('ok',false,'error','已有較新月份總結；舊月份版本保留供查閱，不可倒退發布');
  end if;
  v_result := public.dashboard_line_monthly_apply_internal(v.run_id,v.site_no,v.period_start,v.period_end,
    v.ai_model,v.message_count,v.payload->'events',v.payload->'event_updates',v.payload->'rollup');
  if v_result->>'ok'<>'true' then return v_result; end if;
  update property.line_monthly_summary_versions set status='published',published_by=p_actor,published_at=now() where id=v.id;
  -- Publishing an older reviewed draft must not clobber a newer running/pending attempt's monitor.
  update property.line_monthly_summary_runs r set status=case when latest.status='published' then 'success' else latest.status end,
    message_count=latest.message_count,event_count=case when latest.payload is not null then jsonb_array_length(latest.payload->'events') end,
    ai_model=latest.ai_model,error=latest.error
    from property.line_monthly_summary_versions latest
    where r.id=v.run_id and latest.run_id=r.id and latest.version=r.attempt_count and latest.id<>v.id;
  return v_result || jsonb_build_object('version_id',v.id,'status','published');
end $fn$;

-- Publication is reachable only through a server-authenticated editable employee route.
revoke all on function public.dashboard_line_monthly_prepare_internal(text,date,date,boolean) from public,anon,authenticated,service_role;
revoke all on function public.dashboard_line_monthly_apply_internal(uuid,text,date,date,text,int,jsonb,jsonb,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.dashboard_line_monthly_snapshot(uuid) from public,anon,authenticated,service_role;
revoke all on function public.dashboard_line_monthly_prepare(text,date,date,boolean) from public,anon,authenticated;
revoke all on function public.dashboard_line_monthly_commit(uuid,text,date,date,text,int,jsonb,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.dashboard_line_monthly_versions(text,date) from public,anon,authenticated;
revoke all on function public.dashboard_line_monthly_publish(uuid,text,text) from public,anon,authenticated;
grant execute on function public.dashboard_line_monthly_prepare(text,date,date,boolean) to service_role;
grant execute on function public.dashboard_line_monthly_commit(uuid,text,date,date,text,int,jsonb,jsonb,jsonb) to service_role;
grant execute on function public.dashboard_line_monthly_versions(text,date) to service_role;
grant execute on function public.dashboard_line_monthly_publish(uuid,text,text) to service_role;
