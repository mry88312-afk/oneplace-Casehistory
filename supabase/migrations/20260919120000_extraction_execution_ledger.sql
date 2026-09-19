-- ONE-272: immutable attempts, exact cutoff, source provenance, incremental publication.
create table property.line_extraction_runs (
  id uuid primary key default gen_random_uuid(),
  property_id uuid references property.properties(id), site_no text not null,
  contact_code text not null, group_name text not null,
  cutoff_at timestamptz not null, started_at timestamptz not null default now(),
  finished_at timestamptz, status text not null default 'running'
    check(status in ('running','published','empty','skipped','failed')),
  actor text not null, ai_model text, error text,
  message_ids jsonb not null default '[]', message_count integer not null default 0,
  event_count integer not null default 0, update_count integer not null default 0,
  base_snapshot jsonb not null, payload jsonb
);
alter table property.line_extraction_runs enable row level security;
revoke all on property.line_extraction_runs from public, anon, authenticated;
create index line_extraction_site_started on property.line_extraction_runs(site_no,started_at desc);

create function public.dashboard_line_extraction(p_action text,p_data jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare r property.line_extraction_runs%rowtype; pid uuid; snapshot jsonb; item jsonb;
  inserted integer:=0; updated integer:=0; n integer; cutoff timestamptz;
begin
  if p_action='history' then
    return jsonb_build_object('ok',true,'runs',coalesce((select jsonb_agg(x order by x->>'started_at' desc) from (
      select to_jsonb(a)-'base_snapshot'-'message_ids' as x from property.line_extraction_runs a
        where nullif(p_data->>'site_no','') is null or a.site_no=p_data->>'site_no'
      union all
      select jsonb_build_object('id',v.id,'site_no',v.site_no,'started_at',v.created_at,
        'finished_at',v.published_at,'cutoff_at',v.period_end,'status',v.status,'actor',v.published_by,
        'ai_model',v.ai_model,'error',v.error,'message_count',v.message_count,
        'event_count',coalesce(jsonb_array_length(v.payload->'events'),0),
        'update_count',coalesce(jsonb_array_length(v.payload->'event_updates'),0),'payload',v.payload,
        'legacy',true,'period_start',v.period_start,'period_end',v.period_end)
      from property.line_monthly_summary_versions v
        where nullif(p_data->>'site_no','') is null or v.site_no=p_data->>'site_no'
    ) history),'[]'::jsonb));
  end if;
  if p_action='prepare' then
    perform pg_advisory_xact_lock(hashtextextended('extraction:'||(p_data->>'site_no'),0));
    select id into strict pid from property.properties where site_no=p_data->>'site_no' and deleted_at is null;
    cutoff:=(p_data->>'cutoff_at')::timestamptz;
    if cutoff is null or cutoff>now()+interval '1 minute' then raise exception 'Invalid cutoff'; end if;
    snapshot:=public.dashboard_line_monthly_snapshot(pid);
    insert into property.line_extraction_runs(property_id,site_no,contact_code,group_name,cutoff_at,actor,base_snapshot)
      values(pid,p_data->>'site_no',p_data->>'contact_code',p_data->>'group_name',cutoff,
        coalesce(nullif(p_data->>'actor',''),'system:auto'),snapshot) returning * into r;
    if exists(select 1 from property.line_extraction_runs where property_id=pid and id<>r.id
      and status='running' and started_at>now()-interval '2 hours') then
      update property.line_extraction_runs set status='skipped',error='already_running',finished_at=now() where id=r.id;
      return jsonb_build_object('ok',true,'skipped',true,'run_id',r.id,'reason','already_running');
    end if;
    update property.line_extraction_runs set status='failed',error='expired',finished_at=now()
      where property_id=pid and id<>r.id and status='running';
    return jsonb_build_object('ok',true,'run_id',r.id,'current_rollup',snapshot->'rollup',
      'open_events',coalesce((select jsonb_agg(e || jsonb_build_object('date',e->>'event_date'))
        from jsonb_array_elements(snapshot->'events') e where e->>'source_key' is not null),'[]'::jsonb),
      'processed_ids',coalesce((select jsonb_agg(distinct m) from property.line_extraction_runs a,
        lateral jsonb_array_elements(a.message_ids) m where a.property_id=pid and a.contact_code=r.contact_code
        and a.status in ('published','empty')),'[]'::jsonb));
  end if;
  select * into strict r from property.line_extraction_runs where id=(p_data->>'run_id')::uuid for update;
  if r.status<>'running' then return jsonb_build_object('ok',true,'status',r.status,'inserted',r.event_count,'updated',r.update_count); end if;
  if p_action in ('fail','skip') then
    update property.line_extraction_runs set status=case when p_action='fail' then 'failed' else 'skipped' end,
      error=left(p_data->>'error',1000),finished_at=now() where id=r.id;
    return jsonb_build_object('ok',true);
  end if;
  if p_action<>'commit' then raise exception 'Unknown action'; end if;
  perform pg_advisory_xact_lock(hashtextextended('extraction:'||r.site_no,0));
  lock table property.property_line_events,property.property_line_rollups in share row exclusive mode;
  if r.base_snapshot is distinct from public.dashboard_line_monthly_snapshot(r.property_id) then
    raise exception 'Published content changed; retry extraction';
  end if;
  if jsonb_typeof(p_data->'events') is distinct from 'array' or jsonb_typeof(p_data->'event_updates') is distinct from 'array'
    or jsonb_typeof(p_data->'message_ids') is distinct from 'array' then raise exception 'Invalid payload arrays'; end if;
  if exists(select 1 from jsonb_array_elements(p_data->'events') e group by e->>'event_key' having count(*)>1)
    or exists(select 1 from jsonb_array_elements(p_data->'event_updates') e group by e->>'source_key' having count(*)>1)
    then raise exception 'Duplicate event identity'; end if;
  for item in select value from jsonb_array_elements(p_data->'events') loop
    if coalesce(trim(item->>'event_key'),'')='' or coalesce(trim(item->>'title'),'')=''
      or nullif(item->>'date','') is null or (item->>'date')::date>(r.cutoff_at at time zone 'Asia/Taipei')::date
      or coalesce(item->>'status','') not in ('已完成','追蹤中','未解決','資訊') then raise exception 'Invalid event'; end if;
    insert into property.property_line_events(property_id,event_date,subcat,title,description,followup,status,
      speaker_role,source_file,source_kind,source_period_start,source_period_end,source_key,ai_model,generated_at)
    values(r.property_id,(item->>'date')::date,item->>'subcat',item->>'title',item->>'desc',item->>'followup',item->>'status',
      item->>'speaker','site-management:execution:'||r.id,'site_management_monthly',
      (item->>'date')::date,(r.cutoff_at at time zone 'Asia/Taipei')::date,
      'site-management:execution:'||r.id||':'||(item->>'event_key'),p_data->>'ai_model',now());
    inserted:=inserted+1;
  end loop;
  for item in select value from jsonb_array_elements(p_data->'event_updates') loop
    if coalesce(item->>'status','') not in ('已完成','追蹤中','未解決','資訊') then raise exception 'Invalid event update'; end if;
    update property.property_line_events set followup=item->>'followup',status=item->>'status',
      ai_model=p_data->>'ai_model',generated_at=now()
      where property_id=r.property_id and source_key=item->>'source_key';
    get diagnostics n=row_count;
    if n<>1 then raise exception 'Event update must identify exactly one existing event'; end if;
    updated:=updated+n;
  end loop;
  if coalesce(p_data->'rollup'->>'summary','')<>'' then
    insert into property.property_line_rollups(property_id,summary,completed_items,tracking_items,unresolved_items,
      source_period_start,source_period_end,ai_model,generated_at,updated_at)
    values(r.property_id,p_data->'rollup'->>'summary',p_data->'rollup'->'completed_items',p_data->'rollup'->'tracking_items',
      p_data->'rollup'->'unresolved_items',(r.cutoff_at at time zone 'Asia/Taipei')::date,
      (r.cutoff_at at time zone 'Asia/Taipei')::date,p_data->>'ai_model',now(),now())
    on conflict(property_id) do update set summary=excluded.summary,completed_items=excluded.completed_items,
      tracking_items=excluded.tracking_items,unresolved_items=excluded.unresolved_items,
      source_period_end=excluded.source_period_end,ai_model=excluded.ai_model,generated_at=now(),updated_at=now();
  end if;
  update property.line_extraction_runs set status=case when inserted+updated=0 and coalesce(p_data->'rollup'->>'summary','')='' then 'empty' else 'published' end,
    finished_at=now(),payload=jsonb_build_object('events',p_data->'events','event_updates',p_data->'event_updates','rollup',p_data->'rollup'),
    ai_model=p_data->>'ai_model',message_ids=p_data->'message_ids',message_count=jsonb_array_length(p_data->'message_ids'),
    event_count=inserted,update_count=updated where id=r.id;
  return jsonb_build_object('ok',true,'inserted',inserted,'updated',updated,'run_id',r.id);
end $fn$;
revoke all on function public.dashboard_line_extraction(text,jsonb) from public,anon,authenticated;
grant execute on function public.dashboard_line_extraction(text,jsonb) to service_role;
