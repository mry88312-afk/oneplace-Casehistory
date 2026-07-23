-- 案場歷程頁為公開頁，移除「請款(capex)」時間軸來源，避免財務請款資料對外曝露。
-- 僅刪除 capex UNION 區塊（finance.payment_requests / payment_request_items），其餘不變。
-- 本檔與線上一致（已 apply：timeline_events_remove_capex）
CREATE OR REPLACE FUNCTION public.dashboard_timeline_events(p_property_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
with ev(d, e, cat, title, "desc", amt) as (
  select p.release_date, null::date, 'site', '案場釋出',
         '房源釋出日（properties.release_date）', null::numeric
    from property.properties p
   where p.id = p_property_id and p.release_date is not null
  union all
  select p.measure_date, null, 'site', '工務丈量',
         '丈量日（properties.measure_date)', null
    from property.properties p
   where p.id = p_property_id and p.measure_date is not null
  union all
  select oc.sign_date, null, 'owner',
         '業主約簽約'||coalesce('（'||oc.management_mode||'）',''),
         '契約 '||coalesce(trim(trailing '.0' from oc.contract_total_years::text),'?')||' 年，'
           ||coalesce(to_char(oc.start_date,'YYYY-MM-DD'),'?')||' 起租'
           ||coalesce('，狀態：'||oc.status,''), null
    from contract.owner_contracts oc
   where oc.property_id = p_property_id and oc.deleted_at is null and oc.sign_date is not null
  union all
  select oc.start_date, null, 'owner', '業主約起租',
         '至 '||coalesce(to_char(oc.end_date,'YYYY-MM-DD'),'—')
           ||coalesce('，首次付租 '||to_char(oc.first_rent_payment_date,'YYYY-MM-DD'),''), null
    from contract.owner_contracts oc
   where oc.property_id = p_property_id and oc.deleted_at is null and oc.start_date is not null
  union all
  select oc.rent_free_start, null, 'owner', '免租期開始',
         '至 '||coalesce(to_char(oc.rent_free_end,'YYYY-MM-DD'),'—')
           ||coalesce('，共 '||oc.rent_free_days||' 天',''), null
    from contract.owner_contracts oc
   where oc.property_id = p_property_id and oc.deleted_at is null and oc.rent_free_start is not null
  union all
  select oc.rent_free_end, null, 'owner', '免租期結束',
         '自 '||coalesce(to_char(oc.rent_free_start,'YYYY-MM-DD'),'—')||' 起'
           ||coalesce('，共 '||oc.rent_free_days||' 天',''), null
    from contract.owner_contracts oc
   where oc.property_id = p_property_id and oc.deleted_at is null and oc.rent_free_end is not null
  union all
  select oc.actual_end_date, null, 'owner', '業主約實際終止',
         case when oc.end_date is not null and oc.actual_end_date < oc.end_date
              then '提前終止（原到期 '||to_char(oc.end_date,'YYYY-MM-DD')||'）' else '契約結束' end, null
    from contract.owner_contracts oc
   where oc.property_id = p_property_id and oc.deleted_at is null and oc.actual_end_date is not null
  union all
  select oc.end_date, null, 'owner', '業主約到期',
         case when oc.end_date > current_date then '（未來）' else '' end
           ||coalesce('管理模式：'||oc.management_mode,''), null
    from contract.owner_contracts oc
   where oc.property_id = p_property_id and oc.deleted_at is null and oc.end_date is not null
     and oc.actual_end_date is distinct from oc.end_date
  union all
  select case when st.stage_no = 1 then coalesce(st.frpd, st.stage_start) else st.stage_start end,
         st.stage_end, 'rent',
         case when st.stage_no = 1
              then '第一段租金 $'||to_char(st.rent_amount,'FM999,999,999')||'/月'
              else '業主租金調整 $'||to_char(st.prev_amt,'FM999,999,999')||' → $'||to_char(st.rent_amount,'FM999,999,999')||'/月' end,
         case when st.stage_no = 1
              then coalesce('首次租金支付日 '||to_char(st.frpd,'YYYY-MM-DD')||'，','') else '' end
           ||'本段 '||to_char(st.stage_start,'YYYY-MM-DD')||' ~ '||coalesce(to_char(st.stage_end,'YYYY-MM-DD'),'—'),
         st.rent_amount
    from (
      select g.owner_contract_id,
             min(g.period_start) stage_start,
             max(g.period_end)   stage_end,
             g.rent_amount,
             max(g.frpd)         frpd,
             row_number() over (partition by g.owner_contract_id order by min(g.period_start)) stage_no,
             lag(g.rent_amount)  over (partition by g.owner_contract_id order by min(g.period_start)) prev_amt
        from (
          select h.*,
                 sum(h.chg) over (partition by h.owner_contract_id order by h.period_start) grp
            from (
              select rp.owner_contract_id, rp.period_start, rp.period_end, rp.rent_amount,
                     oc.first_rent_payment_date frpd,
                     case when rp.rent_amount is distinct from
                          lag(rp.rent_amount) over (partition by rp.owner_contract_id order by rp.period_start)
                          then 1 else 0 end chg
                from contract.owner_contract_rent_periods rp
                join contract.owner_contracts oc on oc.id = rp.owner_contract_id
               where oc.property_id = p_property_id and oc.deleted_at is null
                 and rp.period_start is not null and rp.rent_amount is not null ) h ) g
       group by g.owner_contract_id, g.grp, g.rent_amount ) st
  union all
  select sl.switch_date, null, 'switch',
         '案場切換'||coalesce('：'||sl.new_ownership,''),
         coalesce('類別 '||sl.category||'，','')||coalesce('總部內部 '||sl.hq_internal_category||'，','')
           ||coalesce('負責 '||sl.manager_name,'')||coalesce('｜'||sl.note,''), null
    from property.property_switch_log sl
   where sl.property_id = p_property_id and sl.deleted_at is null and sl.switch_date is not null
  union all
  select tc.start_date, null, 'tenant',
         coalesce(u.room_code, u.unit_no, '未知房')||' 起租',
         '$'||to_char(tc.monthly_rent,'FM999,999,999')||'/月，約至 '
           ||coalesce(to_char(tc.end_date,'YYYY-MM-DD'),'—')
           ||coalesce('，簽約 '||tc.signing_manager_name,''), tc.monthly_rent
    from contract.tenant_contracts tc
    left join property.units u on u.id = tc.unit_id
   where tc.property_id = p_property_id and tc.deleted_at is null and tc.start_date is not null
  union all
  select tc.move_out_date, null, 'tenant',
         coalesce(u.room_code, u.unit_no, '未知房')||' 退租',
         coalesce('原因：'||nullif(trim(tc.termination_reason),''),'（未填終止原因）'), null
    from contract.tenant_contracts tc
    left join property.units u on u.id = tc.unit_id
   where tc.property_id = p_property_id and tc.deleted_at is null and tc.move_out_date is not null
  union all
  select f.start_date, null, 'tenant', '第一人入駐 🎉',
         coalesce(f.room_code, f.unit_no, '未知房')||' 房 $'||to_char(f.monthly_rent,'FM999,999,999')||'/月，本案場第一筆租客起租', f.monthly_rent
    from ( select tc.start_date, u.unit_no, u.room_code, tc.monthly_rent
             from contract.tenant_contracts tc
             left join property.units u on u.id = tc.unit_id
            where tc.property_id = p_property_id and tc.deleted_at is null and tc.start_date is not null
            order by tc.start_date limit 1 ) f
  union all
  select rh.listed_date, null, 'listing',
         coalesce(u.room_code, u.unit_no, '未知房')||' 牌價 $'||to_char(rh.listed_rent,'FM999,999,999'),
         coalesce(rh.reason,''), rh.listed_rent
    from property.unit_rent_history rh
    join property.units u on u.id = rh.unit_id
   where u.property_id = p_property_id and rh.listed_date is not null and rh.listed_rent is not null
  union all
  select mf.last_paid_date, null, 'fee',
         '管理費繳納（最近一次）'||coalesce(' $'||to_char(mf.last_paid_amount,'FM999,999,999'),''),
         coalesce('每期 $'||to_char(mf.fee_amount,'FM999,999,999'),'')||coalesce('｜'||mf.payment_cycle,'')
           ||'｜資料僅保留最近一次繳費紀錄', mf.last_paid_amount
    from property.property_management_fees mf
   where mf.property_id = p_property_id and mf.last_paid_date is not null
  union all
  select mf.next_paid_date, null, 'fee',
         '管理費下次應繳',
         coalesce('每期 $'||to_char(mf.fee_amount,'FM999,999,999'),'')||coalesce('｜'||mf.payment_cycle,''), mf.fee_amount
    from property.property_management_fees mf
   where mf.property_id = p_property_id and mf.next_paid_date is not null
  union all
  select coalesce(rv.actual_start_date, rv.planned_start_date),
         coalesce(rv.actual_end_date, rv.planned_end_date), 'works',
         '工務進場'||case when rv.is_first_project then '（首案）' else '' end
           ||coalesce('｜'||rv.phase,''),
         coalesce('狀態 '||rv.status||'，','')
           ||case when rv.actual_start_date is null then '（預計日期）' else '' end
           ||coalesce('花費 $'||to_char(coalesce(rv.actual_cost,rv.budget),'FM999,999,999'),'')
           ||coalesce('｜'||rv.notes,''),
         coalesce(rv.actual_cost, rv.budget)
    from property.property_renovations rv
   where rv.property_id = p_property_id
     and coalesce(rv.actual_start_date, rv.planned_start_date) is not null
  union all
  select mt.created_at::date, mt.completed_date, 'works',
         '修繕：'||coalesce(nullif(trim(mt.task_summary),''),'（無摘要）'),
         coalesce('單號 '||mt.ticket_no||'，','')||coalesce('狀態 '||mt.status,'')
           ||coalesce('，房間 '||mt.reporter_unit_no,'')
           ||coalesce('，費用 $'||to_char(mt.total_cost,'FM999,999,999'),''), mt.total_cost
    from service.maintenance_tickets mt
   where mt.property_id = p_property_id and mt.deleted_at is null
  union all
  select vt.scheduled_at::date, null, 'viewing',
         coalesce(u.room_code, u.unit_no, '未知房')||' 帶看',
         coalesce('狀態 '||vt.viewing_status,'')||coalesce('，可承租 '||vt.can_rent,'')
           ||coalesce('，預計起租 '||to_char(vt.planned_start_date,'YYYY-MM-DD'),''), null
    from contract.viewing_tasks vt
    join property.units u on u.id = vt.unit_id
   where u.property_id = p_property_id and vt.deleted_at is null and vt.scheduled_at is not null
  union all
  select coalesce(st.sign_date, st.scheduled_at::date), null, 'viewing',
         coalesce(u.room_code, u.unit_no, '未知房')||' 簽約任務',
         coalesce('狀態 '||st.signing_status,'')
           ||coalesce('，簽約租金 $'||to_char(st.signed_rent,'FM999,999,999'),'')
           ||coalesce('，起租 '||to_char(st.start_date,'YYYY-MM-DD'),''), st.signed_rent
    from contract.signing_tasks st
    join property.units u on u.id = st.unit_id
   where u.property_id = p_property_id and st.deleted_at is null
     and coalesce(st.sign_date, st.scheduled_at::date) is not null
  union all
  select ut.contract_start_date, ut.contract_end_date, 'utility',
         coalesce(ut.utility_type,'水電')||'合約'||coalesce('｜'||ut.provider,''),
         coalesce('方案 '||ut.plan_name,'')||coalesce('｜'||ut.note,''), null
    from property.property_utilities ut
   where ut.property_id = p_property_id and ut.contract_start_date is not null
  union all
  select ut.last_paid_from, ut.last_paid_to, 'utility',
         coalesce(ut.utility_type,'水電')||'繳費（最近一次）'||coalesce(' $'||to_char(ut.last_paid_amount,'FM999,999,999'),''),
         '資料僅保留最近一次繳費區間', ut.last_paid_amount
    from property.property_utilities ut
   where ut.property_id = p_property_id and ut.last_paid_from is not null
  union all
  select ut.next_payment_date, null, 'utility',
         coalesce(ut.utility_type,'水電')||'下次繳費', '', null
    from property.property_utilities ut
   where ut.property_id = p_property_id and ut.next_payment_date is not null
  union all
  select cc.check_date, null, 'works',
         '工務驗收'||coalesce('｜'||cc.phase,''),
         coalesce('結果 '||cc.overall_result,''), null
    from service.construction_checklists cc
   where cc.property_id = p_property_id and cc.check_date is not null
  union all
  select sc.check_date, null, 'works',
         '服務檢查'||case when sc.check_completed then '（完成）' else '' end,
         '', null
    from service.service_checklists sc
   where sc.property_id = p_property_id and sc.check_date is not null
  union all
  select ol.event_date, null, 'oplog',
         '工務日誌：'||coalesce(nullif(left(trim(ol.summary),30),''),'（無摘要）'),
         coalesce('類型 '||ol.log_type||'｜','')||coalesce(trim(ol.summary),''), null
    from service.operation_logs ol
   where ol.property_id = p_property_id and ol.event_date is not null
  union all
  select le.event_date, null, 'line',
         coalesce(le.subcat||'｜','')||le.title
           ||coalesce('【'||nullif(le.status,'資訊')||'】',''),
         coalesce(le.description,'')
           ||coalesce('｜後續：'||nullif(le.followup,''),'')
           ||coalesce('（'||le.speaker_role||'）',''), null
    from property.property_line_events le
   where le.property_id = p_property_id
)
select coalesce(jsonb_agg(jsonb_build_object(
    'date', to_char(d,'YYYY-MM-DD'),
    'end',  case when e is not null then to_char(e,'YYYY-MM-DD') end,
    'cat',  cat, 'title', title, 'desc', "desc", 'amount', amt
  ) order by d), '[]'::jsonb)
from ev;
$function$;
