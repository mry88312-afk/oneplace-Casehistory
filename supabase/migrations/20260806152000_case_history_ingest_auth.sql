-- Keep the integration credential as a one-way hash in Postgres so Zeabur can
-- be configured through API without copying a plaintext secret into Supabase settings.
create table if not exists property.integration_secret_hashes (
  name text primary key,
  secret_hash text not null,
  updated_at timestamptz not null default now(),
  constraint integration_secret_hashes_sha256 check (secret_hash ~ '^[0-9a-f]{64}$')
);

alter table property.integration_secret_hashes enable row level security;
revoke all on property.integration_secret_hashes from public, anon, authenticated;

create or replace function public.dashboard_case_history_authorize(p_secret text)
returns boolean language sql stable security definer set search_path=public,extensions as $fn$
  select coalesce((
    select h.secret_hash = encode(extensions.digest(coalesce(p_secret,''), 'sha256'), 'hex')
      from property.integration_secret_hashes h
     where h.name = 'case_history_ingest'
  ), false);
$fn$;

revoke all on function public.dashboard_case_history_authorize(text) from public, anon, authenticated;
grant execute on function public.dashboard_case_history_authorize(text) to service_role;

comment on table property.integration_secret_hashes
  is 'One-way hashes for service integrations; plaintext credentials stay in the calling service secret store.';
