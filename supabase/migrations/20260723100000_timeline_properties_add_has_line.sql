-- ============================================================
-- 案場歷程：案場清單 RPC 多回 has_line
--   has_line = 該案場是否已有 LINE 對話事件（property_line_events）
--   用途：case-history.html 顯示 LINE 覆蓋率 + 「只看尚缺 LINE」篩選
-- 本檔與線上一致（已 apply：timeline_properties_add_has_line）
-- ============================================================
CREATE OR REPLACE FUNCTION public.dashboard_timeline_properties()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id,
      'site_no', p.site_no,
      'name', coalesce(nullif(p.short_name,''), p.site_no),
      'status', p.status,
      'region', p.ownership_region,
      'city', p.city,
      'district', p.district,
      'has_line', exists(
        select 1 from property.property_line_events e where e.property_id = p.id
      )
    ) order by p.site_no), '[]'::jsonb)
  from property.properties p;
$function$;
