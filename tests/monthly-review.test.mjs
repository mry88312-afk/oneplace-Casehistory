import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
await db.exec(`create role anon; create role authenticated; create role service_role;
create schema property;
create table property.properties(id uuid primary key default gen_random_uuid(),site_no text,short_name text);
create table property.property_line_events(id uuid primary key default gen_random_uuid(),property_id uuid references property.properties(id),
  event_date date,subcat text,title text,description text,followup text,status text,speaker_role text,source_file text,created_at timestamptz default now());
insert into property.properties(site_no,short_name) values('test','Test');`);
await db.exec(await readFile(new URL('../supabase/migrations/20260806150000_line_monthly_summary.sql', import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../supabase/migrations/20260910174000_monthly_review_versions.sql', import.meta.url),'utf8'));
const rpc = async (name,args) => (await db.query(`select public.${name}(${args.map((_,i)=>`$${i+1}`).join(',')}) as result`,args)).rows[0].result;
const prepare = (month='2026-08',force=true) => rpc('dashboard_line_monthly_prepare',['test',`${month}-01`,`${month}-${month.endsWith('09')?'30':'31'}`,force]);
const rollup = summary => ({summary,completed_items:[],tracking_items:[],unresolved_items:[]});
const payload = (title='V1',date='2026-08-12') => [{event_key:'event',date,subcat:'工務',title,desc:title,followup:'',status:'資訊',speaker:'Test'}];
const commit = (id,title='V1',month='2026-08',events=payload(title,`${month}-12`)) => rpc('dashboard_line_monthly_commit',
  [id,'test',`${month}-01`,`${month}-${month.endsWith('09')?'30':'31'}`,'test-model',3,JSON.stringify(events),'[]',JSON.stringify(rollup(title))]);
const publish = (id,actor='site-management:123:Reviewer',site='test') => rpc('dashboard_line_monthly_publish',[id,site,actor]);
const snapshot = async () => (await db.query('select public.dashboard_line_monthly_snapshot(id) as result from property.properties')).rows[0].result;
let first,second,third,published;

await test('draft generation leaves published events/rollup unchanged; duplicate commit is idempotent',async()=>{
  const before=await snapshot(); first=(await prepare()).run_id;
  assert.equal((await commit(first)).status,'pending_review');
  assert.deepEqual(await snapshot(),before);
  assert.equal((await commit(first,'Overwrite attempt')).status,'pending_review');
  const list=await rpc('dashboard_line_monthly_versions',['test','2026-08-01']);
  assert.equal(list.length,1); assert.equal(list[0].payload.rollup.summary,'V1');
});
await test('scheduled retry skips pending drafts; explicit regeneration retains both versions',async()=>{
  assert.equal((await prepare('2026-08',false)).reason,'pending_review');
  second=(await prepare()).run_id; assert.notEqual(first,second);
  assert.equal((await prepare()).reason,'already_running');
  await commit(second,'V2');
  assert.equal((await rpc('dashboard_line_monthly_versions',['test','2026-08-01'])).length,2);
});
await test('publication requires actor and exact site; anon cannot execute or read versions',async()=>{
  assert.equal((await publish(first,'')).ok,false);
  assert.equal((await publish(first,'reviewer','wrong')).ok,false);
  for(const role of ['anon','authenticated']) {
    assert.equal((await db.query("select has_function_privilege($1,'public.dashboard_line_monthly_publish(uuid,text,text)','EXECUTE') as allowed",[role])).rows[0].allowed,false);
  }
  assert.equal((await db.query("select has_function_privilege('service_role','public.dashboard_line_monthly_apply_internal(uuid,text,date,date,text,integer,jsonb,jsonb,jsonb)','EXECUTE') as allowed")).rows[0].allowed,false);
});
await test('human publication updates IAM read projection and records actor; preserves newer pending monitor',async()=>{
  assert.equal((await publish(first)).ok,true); published=await snapshot();
  assert.equal(published.events.length,1); assert.equal(published.rollup.summary,'V1');
  assert.equal((await db.query('select status from property.line_monthly_summary_runs')).rows[0].status,'pending_review');
  assert.equal((await rpc('dashboard_line_rollup',[published.rollup.property_id])).summary,'V1');
  assert.equal((await publish(first)).already_published,true);
  assert.deepEqual(await snapshot(),published);
});
await test('stale reviewed draft cannot replace changed published content',async()=>{
  assert.equal((await publish(second)).ok,false); assert.deepEqual(await snapshot(),published);
});
await test('new draft snapshots legacy/current published data; publish retains prior payload and snapshot',async()=>{
  third=(await prepare()).run_id; await commit(third,'V3');
  assert.deepEqual(await snapshot(),published);
  assert.equal((await publish(third)).ok,true);
  const rows=(await db.query('select base_snapshot,payload,published_by from property.line_monthly_summary_versions where id=$1',[third])).rows;
  assert.deepEqual(rows[0].base_snapshot,published); assert.equal(rows[0].published_by,'site-management:123:Reviewer');
  assert.equal((await snapshot()).rollup.summary,'V3');
  assert.equal((await prepare('2026-08',false)).reason,'already_success');
});
await test('failed/retried extraction never destroys prior versions or published data; error secrets redacted',async()=>{
  const before=await snapshot(); const attempt=(await prepare()).run_id;
  await rpc('dashboard_line_monthly_fail',[attempt,'bad key sk-proj-secret']);
  assert.equal((await prepare('2026-08',false)).reason,'retry_cooldown');
  assert.equal((await commit(attempt)).ok,false);
  assert.deepEqual(await snapshot(),before);
  const versions=await rpc('dashboard_line_monthly_versions',['test','2026-08-01']);
  assert.equal(versions[0].error,'bad key [REDACTED]');
});
await test('expired workers cannot commit or fail a newer attempt',async()=>{
  const old=(await prepare()).run_id;
  await db.exec("update property.line_monthly_summary_runs set started_at=now()-interval '3 hours'");
  const fresh=(await prepare()).run_id;
  assert.equal((await commit(old)).ok,false);
  await rpc('dashboard_line_monthly_fail',[old,'late error']);
  assert.equal((await db.query('select status from property.line_monthly_summary_runs')).rows[0].status,'running');
  await commit(fresh,'V6');
});
await test('invalid dates and duplicate keys are rejected before pending review',async()=>{
  const id=(await prepare()).run_id;
  await assert.rejects(()=>commit(id,'bad','2026-08',payload('bad','2026-09-01')));
  await assert.rejects(()=>commit(id,'bad','2026-08',[...payload(),...payload()]));
  await rpc('dashboard_line_monthly_fail',[id,'invalid']);
});
await test('newer month remains published when old month is regenerated; future context excluded',async()=>{
  const sept=(await prepare('2026-09')).run_id; await commit(sept,'September','2026-09'); await publish(sept);
  const before=await snapshot(); const old=await prepare();
  assert.equal(old.current_rollup,null); assert.equal(old.open_events.length,0);
  await commit(old.run_id,'Old August');
  assert.equal((await publish(old.run_id)).ok,false); assert.deepEqual(await snapshot(),before);
});
await test('manual projection changes while awaiting review reject publication',async()=>{
  const id=(await prepare('2026-09')).run_id; await commit(id,'September rerun','2026-09');
  await db.exec("update property.property_line_rollups set summary='Manual edit'");
  assert.equal((await publish(id)).ok,false); assert.equal((await snapshot()).rollup.summary,'Manual edit');
});
await db.close();
