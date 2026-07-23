-- ============================================================
-- 改為「多人上傳、不跑 AI」流程（本檔與線上一致，已 apply）
--  1) enqueue 改案場層級去重（同案場已上傳或已有事件 → 擋，除非 force）
--     不再依檔名去重，避免同案場不同檔名被重複上傳；純存檔不觸發萃取
--  2) timeline_properties 多回 has_upload（是否已有人上傳原始檔）
-- ============================================================

-- 1) enqueue：案場層級去重（純存檔）
create or replace function public.dashboard_line_enqueue(
  p_site_no text, p_source_file text, p_transcript text, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_pid uuid; v_name text; v_has_job boolean; v_has_evt boolean; v_job uuid;
begin
  select p.id, coalesce(nullif(p.short_name,''), p.site_no) into v_pid, v_name
    from property.properties p where p.site_no = p_site_no limit 1;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error', '找不到案場編號 '||coalesce(p_site_no,'(空)'));
  end if;

  if p_transcript is null or length(trim(p_transcript)) < 20 then
    return jsonb_build_object('ok', false, 'error', '對話內容太短或空白');
  end if;

  -- 案場層級去重：已有任何上傳 job 或已有萃取事件 → 視為已上傳
  select exists(select 1 from property.line_ingest_jobs where property_id = v_pid) into v_has_job;
  select exists(select 1 from property.property_line_events where property_id = v_pid) into v_has_evt;
  if (v_has_job or v_has_evt) and not p_force then
    return jsonb_build_object('ok', true, 'skipped', true, 'already_uploaded', true,
                              'site_no', p_site_no, 'name', v_name);
  end if;

  insert into property.line_ingest_jobs (property_id, site_no, source_file, transcript, force)
  values (v_pid, p_site_no, p_source_file, p_transcript, p_force)
  returning id into v_job;
  return jsonb_build_object('ok', true, 'queued', true, 'job_id', v_job,
                            'site_no', p_site_no, 'name', v_name);
end $fn$;

-- 2) 案場清單 RPC 多回 has_upload（保留 has_line）
create or replace function public.dashboard_timeline_properties()
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id,
      'site_no', p.site_no,
      'name', coalesce(nullif(p.short_name,''), p.site_no),
      'status', p.status,
      'region', p.ownership_region,
      'city', p.city,
      'district', p.district,
      'has_upload', exists(select 1 from property.line_ingest_jobs j where j.property_id = p.id),
      'has_line',   exists(select 1 from property.property_line_events e where e.property_id = p.id)
    ) order by p.site_no), '[]'::jsonb)
  from property.properties p;
$fn$;
