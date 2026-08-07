-- Case History monthly monitoring read-back for site-management.
-- Read-only and service-role only: returns the committed run, events, and rollup
-- for the requested site numbers and month so the caller can verify persistence.

create or replace function public.dashboard_line_monthly_monitor(
  p_site_nos text[],
  p_period_start date,
  p_period_end date)
returns jsonb language sql stable security definer set search_path=public as $fn$
  with requested as (
    select distinct trim(value) as site_no
      from unnest(coalesce(p_site_nos, array[]::text[])) value
     where coalesce(trim(value), '') <> ''
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'site_no', requested.site_no,
    'property_id', property_row.id,
    'name', coalesce(nullif(property_row.short_name, ''), requested.site_no),
    'run', coalesce(run_row.payload, 'null'::jsonb),
    'events', coalesce(event_rows.payload, '[]'::jsonb),
    'rollup', coalesce(rollup_row.payload, 'null'::jsonb)
  ) order by requested.site_no), '[]'::jsonb)
    from requested
    left join lateral (
      select p.id, p.short_name
        from property.properties p
       where p.site_no = requested.site_no
       order by p.id
       limit 1
    ) property_row on true
    left join lateral (
      select jsonb_build_object(
        'id', r.id,
        'status', r.status,
        'attempt_count', r.attempt_count,
        'message_count', r.message_count,
        'event_count', r.event_count,
        'ai_model', r.ai_model,
        'error', r.error,
        'started_at', r.started_at,
        'finished_at', r.finished_at
      ) as payload
        from property.line_monthly_summary_runs r
       where r.property_id = property_row.id
         and r.period_start = p_period_start
         and r.period_end = p_period_end
       limit 1
    ) run_row on true
    left join lateral (
      select jsonb_agg(jsonb_build_object(
        'date', to_char(e.event_date, 'YYYY-MM-DD'),
        'subcat', e.subcat,
        'title', e.title,
        'description', e.description,
        'followup', e.followup,
        'status', e.status,
        'speaker', e.speaker_role,
        'source_key', e.source_key,
        'ai_model', e.ai_model,
        'generated_at', e.generated_at
      ) order by e.event_date, e.created_at) as payload
        from property.property_line_events e
       where e.property_id = property_row.id
         and e.source_kind = 'site_management_monthly'
         and e.source_period_start = p_period_start
         and e.source_period_end = p_period_end
    ) event_rows on true
    left join lateral (
      select jsonb_build_object(
        'summary', r.summary,
        'completed_items', r.completed_items,
        'tracking_items', r.tracking_items,
        'unresolved_items', r.unresolved_items,
        'source_period_start', to_char(r.source_period_start, 'YYYY-MM-DD'),
        'source_period_end', to_char(r.source_period_end, 'YYYY-MM-DD'),
        'ai_model', r.ai_model,
        'generated_at', r.generated_at
      ) as payload
        from property.property_line_rollups r
       where r.property_id = property_row.id
         and r.source_period_start = p_period_start
         and r.source_period_end = p_period_end
       limit 1
    ) rollup_row on true;
$fn$;

revoke all on function public.dashboard_line_monthly_monitor(text[],date,date)
  from public, anon, authenticated;
grant execute on function public.dashboard_line_monthly_monitor(text[],date,date)
  to service_role;

comment on function public.dashboard_line_monthly_monitor(text[],date,date)
  is 'Read-back of Case History monthly runs, committed events, and rollups for site-management monitoring';
