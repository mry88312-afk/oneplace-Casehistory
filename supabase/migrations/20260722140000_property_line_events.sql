-- ============================================================
-- 案場歷程「LINE 對話記錄」類別：資料表 + edge function 用的 RPC
-- 事件由 edge function `line-extract` 呼叫 Claude 從 LINE txt 萃取後入庫。
-- timeline UNION 段（cat 'line'）在 20260722130000_property_timeline_rpcs.sql。
-- ============================================================

create table if not exists property.property_line_events (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references property.properties(id) on delete cascade,
  event_date date not null,
  subcat text,                -- 洽談/房況/工務/定價/排程/異常/里程碑
  title text not null,
  description text,
  speaker_role text,
  source_file text,           -- 來源 txt 檔名，重傳同檔用來覆蓋
  created_at timestamptz not null default now()
);
create index if not exists idx_line_events_property on property.property_line_events(property_id);
create index if not exists idx_line_events_source on property.property_line_events(property_id, source_file);
comment on table property.property_line_events is 'LINE 群組對話經 LLM 萃取的營運事件，供案場歷程時間軸 line 類別使用';

-- 從檔名的案場編號 / 地址對應 property（edge function 用 service_role 呼叫）
create or replace function public.dashboard_resolve_property(p_site_no text default null, p_address text default null)
returns jsonb language sql stable security definer set search_path=public as $fn$
  select coalesce((
    select jsonb_build_object(
             'id', p.id, 'site_no', p.site_no,
             'name', coalesce(nullif(p.short_name,''), p.site_no),
             'address', p.address_full)
      from property.properties p
     where (p_site_no is not null and p.site_no = p_site_no)
        or (p_address is not null and length(p_address) > 4 and p.address_full ilike '%'||p_address||'%')
     order by (p.site_no is not distinct from p_site_no) desc
     limit 1
  ), '{}'::jsonb);
$fn$;

-- LINE 萃取事件入庫：同案場+同來源檔先刪後插（重傳覆蓋）
create or replace function public.dashboard_line_upsert(p_property_id uuid, p_source_file text, p_events jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_count int;
begin
  delete from property.property_line_events
   where property_id = p_property_id and source_file = p_source_file;
  insert into property.property_line_events
    (property_id, event_date, subcat, title, description, speaker_role, source_file)
  select p_property_id,
         (e->>'date')::date,
         nullif(e->>'subcat',''),
         left(e->>'title', 200),
         nullif(e->>'desc',''),
         nullif(e->>'speaker',''),
         p_source_file
    from jsonb_array_elements(p_events) e
   where e->>'date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     and coalesce(trim(e->>'title'),'') <> '';
  get diagnostics v_count = row_count;
  return jsonb_build_object('inserted', v_count);
end $fn$;

revoke all on function public.dashboard_resolve_property(text, text) from public, anon;
revoke all on function public.dashboard_line_upsert(uuid, text, jsonb) from public, anon;
grant execute on function public.dashboard_resolve_property(text, text) to service_role;
grant execute on function public.dashboard_line_upsert(uuid, text, jsonb) to service_role;
