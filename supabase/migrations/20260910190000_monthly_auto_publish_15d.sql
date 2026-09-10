-- ONE-242: run on the 1st and 16th, publish successful AI output automatically.
alter table property.line_monthly_summary_versions drop constraint if exists line_monthly_summary_versions_status_check;
alter table property.line_monthly_summary_versions add constraint line_monthly_summary_versions_status_check
  check (status in ('running','pending_review','published','failed','skipped'));
alter table property.line_monthly_summary_runs drop constraint if exists line_monthly_summary_runs_status;
alter table property.line_monthly_summary_runs add constraint line_monthly_summary_runs_status
  check (status in ('running','success','failed','pending_review','skipped'));

create or replace function public.dashboard_line_monthly_commit(
  p_run_id uuid,p_site_no text,p_period_start date,p_period_end date,p_ai_model text,
  p_message_count int,p_events jsonb,p_event_updates jsonb,p_rollup jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v property.line_monthly_summary_versions%rowtype; v_result jsonb;
begin
  select * into v from property.line_monthly_summary_versions where id=p_run_id for update;
  if not found then return jsonb_build_object('ok',false,'error','version_not_found'); end if;
  if v.site_no is distinct from trim(p_site_no) or v.period_start is distinct from p_period_start
    or v.period_end is distinct from p_period_end then
    return jsonb_build_object('ok',false,'error','version_scope_mismatch');
  end if;
  if v.status='published' then
    return jsonb_build_object('ok',true,'status','published','version_id',v.id,'inserted',coalesce(jsonb_array_length(v.payload->'events'),0));
  end if;
  if v.status<>'running' then return jsonb_build_object('ok',false,'error','version_not_running'); end if;
  v_result := public.dashboard_line_monthly_apply_internal(v.run_id,v.site_no,v.period_start,v.period_end,
    p_ai_model,p_message_count,p_events,p_event_updates,p_rollup);
  if v_result->>'ok'<>'true' then return v_result; end if;
  update property.line_monthly_summary_versions set status='published',
    payload=jsonb_build_object('events',p_events,'event_updates',p_event_updates,'rollup',p_rollup),
    ai_model=p_ai_model,message_count=p_message_count,published_by='system:auto',published_at=now(),error=null
    where id=v.id;
  update property.line_monthly_summary_runs set status='success',message_count=p_message_count,
    event_count=jsonb_array_length(p_events),ai_model=p_ai_model,error=null,finished_at=now(),updated_at=now()
    where id=v.run_id and attempt_count=v.version;
  return v_result || jsonb_build_object('version_id',v.id,'status','published');
end $fn$;

create or replace function public.dashboard_line_monthly_skip(p_run_id uuid,p_error text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v property.line_monthly_summary_versions%rowtype; v_error text;
begin
  v_error := left(regexp_replace(coalesce(p_error,'skipped'),'sk-[A-Za-z0-9_*-]+','[REDACTED]','g'),1000);
  update property.line_monthly_summary_versions set status='skipped',error=v_error
    where id=p_run_id and status='running' returning * into v;
  if not found then return jsonb_build_object('ok',false,'error','version_not_running'); end if;
  update property.line_monthly_summary_runs set status='skipped',error=v_error,finished_at=now(),updated_at=now()
    where id=v.run_id and attempt_count=v.version;
  return jsonb_build_object('ok',true,'status','skipped','version_id',v.id);
end $fn$;

revoke all on function public.dashboard_line_monthly_skip(uuid,text) from public,anon,authenticated;
grant execute on function public.dashboard_line_monthly_skip(uuid,text) to service_role;
