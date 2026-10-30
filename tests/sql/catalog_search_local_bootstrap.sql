-- Disposable vanilla PostgreSQL fixture ONLY; never run on production.
-- Creates minimum Auth/sync/data objects needed to test catalog migrations.
-- This is intentionally not an emulator of Supabase Auth/PostgREST/JWT gateways.
begin;
create schema auth;
create table auth.users (
    id uuid primary key,
    email text,
    is_anonymous boolean not null default false,
    deleted_at timestamptz,
    banned_until timestamptz
);
create function auth.role()
returns text language sql stable set search_path=pg_catalog as $$
    select nullif(pg_catalog.current_setting('request.jwt.claim.role',true),'')
$$;
create function auth.uid()
returns uuid language sql stable set search_path=pg_catalog as $$
    select nullif(pg_catalog.current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.role(), auth.uid() to anon, authenticated, service_role;

create schema pintheory_sync authorization postgres;
create table pintheory_sync.accounts (
    user_id uuid primary key,
    state text not null default 'active'
);
revoke all on schema pintheory_sync from public, anon, authenticated, service_role;
revoke all on table pintheory_sync.accounts from public, anon, authenticated, service_role;

create schema pintheory_data authorization postgres;
create function pintheory_data.require_service()
returns void language plpgsql security definer set search_path=pg_catalog as $$
begin
    if auth.role() is distinct from 'service_role' then
        raise exception using errcode='42501',message='service_role_required';
    end if;
end;
$$;
create function pintheory_data.user_allowed(p_user_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog as $$
begin
    perform pintheory_data.require_service();
    return exists(select 1 from auth.users u where u.id=p_user_id
        and u.is_anonymous is false and u.deleted_at is null
        and (u.banned_until is null or u.banned_until <= pg_catalog.clock_timestamp()))
      and not exists(select 1 from pintheory_sync.accounts a
        where a.user_id=p_user_id and a.state in ('blocked','deleting'));
end;
$$;
revoke all on schema pintheory_data from public, anon, authenticated, service_role;
revoke all on all functions in schema pintheory_data from public, anon, authenticated, service_role;
commit;
