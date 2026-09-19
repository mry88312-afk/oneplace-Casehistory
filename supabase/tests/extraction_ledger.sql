begin;
do $test$
declare prep jsonb; rid uuid; result jsonb; k text; saved jsonb; caught boolean:=false;
begin
prep:=public.dashboard_line_extraction('prepare',jsonb_build_object('site_no','441','contact_code','ONE-272-transaction-test','group_name','rollback test','cutoff_at',now(),'actor','ONE-272:test'));
rid:=(prep->>'run_id')::uuid;
result:=public.dashboard_line_extraction('commit',jsonb_build_object('run_id',rid,'ai_model','test','message_ids','[2147480000]'::jsonb,
 'events',jsonb_build_array(jsonb_build_object('event_key','test','date',(now() at time zone 'Asia/Taipei')::date,'title','ONE-272 rollback fixture','subcat','工務','status','追蹤中','desc','transaction only','followup','pending')),
 'event_updates','[]'::jsonb,'rollup',null));
if (result->>'inserted')::int<>1 then raise exception 'Insert failed'; end if;
result:=public.dashboard_line_extraction('commit',jsonb_build_object('run_id',rid));
if (result->>'inserted')::int<>1 then raise exception 'Idempotent reply failed'; end if;
k:='site-management:execution:'||rid||':test';
if (select count(*) from property.property_line_events where source_key=k)<>1 then raise exception 'Duplicate insertion'; end if;
prep:=public.dashboard_line_extraction('prepare',jsonb_build_object('site_no','441','contact_code','ONE-272-transaction-test','group_name','rollback test','cutoff_at',now(),'actor','ONE-272:test'));
if not (prep->'processed_ids' @> '[2147480000]'::jsonb) then raise exception 'Processed message lost'; end if;
rid:=(prep->>'run_id')::uuid;
begin
 perform public.dashboard_line_extraction('commit',jsonb_build_object('run_id',rid,'events','[]'::jsonb,'event_updates',jsonb_build_array(jsonb_build_object('source_key','foreign-site-key','status','已完成','followup','bad')),'message_ids','[]'::jsonb,'rollup',null));
exception when others then caught:=true;
end;
if not caught then raise exception 'Unknown source accepted'; end if;
result:=public.dashboard_line_extraction('commit',jsonb_build_object('run_id',rid,'events','[]'::jsonb,'event_updates',jsonb_build_array(jsonb_build_object('source_key',k,'status','已完成','followup','verified')),'message_ids','[2147480001]'::jsonb,'rollup',null));
if (result->>'updated')::int<>1 or not exists(select 1 from property.property_line_events where source_key=k and status='已完成' and followup='verified') then raise exception 'Update failed'; end if;
end $test$;
rollback;
select 'insert_update_idempotency_processed_ids_and_unknown_source_passed_rolled_back' as result;
