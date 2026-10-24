-- Forward-only, NOT EXECUTED. Requires ALL THREE preceding migrations, in order:
-- 202610190001_sync_foundation.sql, 202610210001_account_deletion.sql,
-- 202610230001_sync_domain_validation.sql. Apply as postgres after staging review.
-- Do not expose pintheory_admin through PostgREST or Realtime.
begin;

-- Fail closed on missing dependencies; never conceal drift with IF NOT EXISTS.
do $$
begin
    if pg_catalog.to_regclass('pintheory_sync.accounts') is null
       or pg_catalog.to_regclass('pintheory_sync.records') is null
       or pg_catalog.to_regclass('pintheory_sync.change_events') is null
       or pg_catalog.to_regclass('pintheory_sync.mutation_receipts') is null
       or pg_catalog.to_regprocedure('public.pintheory_purge_account(uuid)') is null
       or pg_catalog.to_regprocedure('public.pintheory_sync_capabilities()') is null
       or pg_catalog.to_regprocedure('pintheory_sync.payload_valid(text,jsonb)') is null then
        raise exception 'all three prior sync migrations are required';
    end if;
end;
$$;

create schema pintheory_admin authorization postgres;
revoke all on schema pintheory_admin from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_admin
    revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_admin
    revoke all on functions from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_admin
    revoke all on sequences from public, anon, authenticated, service_role;

-- Aggregate-only retention: no UID, email, event log, or per-user deduplication.
-- The boolean PK plus CHECK permits precisely one possible singleton key.
create table pintheory_admin.account_counters (
    singleton boolean primary key default true check (singleton),
    tracking_started_at timestamptz not null,
    known_registrations bigint not null check (known_registrations >= 0),
    known_deletions bigint not null check (known_deletions >= 0)
);
alter table pintheory_admin.account_counters owner to postgres;
alter table pintheory_admin.account_counters enable row level security;

-- Wait out existing Auth writes and prevent writes between baseline and trigger
-- installation. Reads remain allowed. Held through COMMIT; schedule appropriately.
lock table auth.users in share row exclusive mode;
insert into pintheory_admin.account_counters (
    singleton, tracking_started_at, known_registrations, known_deletions
)
select true, pg_catalog.statement_timestamp(), pg_catalog.count(*),
       pg_catalog.count(*) filter (where u.deleted_at is not null)
from auth.users u
where u.is_anonymous is false;

-- Lifetime figures are lower bounds: identities physically removed before the
-- baseline cannot be reconstructed. Counters describe observed events, not a
-- conservation equation if privileged operators restore or reclassify users.
create function pintheory_admin.track_account_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_registrations bigint := 0;
    v_deletions bigint := 0;
begin
    if tg_op = 'INSERT' then
        if new.is_anonymous is false then v_registrations := 1; end if;
    elsif tg_op = 'UPDATE' then
        if old.is_anonymous is true and new.is_anonymous is false then
            v_registrations := 1;
        end if;
        if new.is_anonymous is false
           and old.deleted_at is null and new.deleted_at is not null then
            v_deletions := 1;
        end if;
    elsif tg_op = 'DELETE' then
        if old.is_anonymous is false and old.deleted_at is null then
            v_deletions := 1;
        end if;
    end if;

    if v_registrations <> 0 or v_deletions <> 0 then
        -- Atomic increments serialize on one row; failure rolls back Auth DML.
        update pintheory_admin.account_counters
        set known_registrations = known_registrations + v_registrations,
            known_deletions = known_deletions + v_deletions
        where singleton;
        if not found then
            raise exception 'admin account counter singleton missing';
        end if;
    end if;
    -- AFTER trigger: no changes to Auth rows or existing sync purge behavior.
    return null;
end;
$$;
alter function pintheory_admin.track_account_event() owner to postgres;
create trigger pintheory_admin_account_event
    after insert or update of is_anonymous, deleted_at or delete on auth.users
    for each row execute function pintheory_admin.track_account_event();

create function public.pintheory_admin_account_metrics()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
    v_now timestamptz := pg_catalog.statement_timestamp();
    v_result jsonb;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception using errcode = '42501', message = 'service_role_required';
    end if;

    -- STABLE uses the calling statement's MVCC snapshot for all logical reads.
    -- Physical sizes are operational readings, not MVCC/account-only sizes.
    with eligible as materialized (
        select u.id, u.last_sign_in_at
        from auth.users u
        where u.is_anonymous is false and u.deleted_at is null
    ), byte_parts as (
        select r.user_id, pg_catalog.sum(pg_catalog.pg_column_size(r.payload)) as bytes,
               'records'::text as part
        from pintheory_sync.records r join eligible u on u.id = r.user_id
        group by r.user_id
        union all
        select e.user_id, pg_catalog.sum(pg_catalog.pg_column_size(e.record)), 'history'
        from pintheory_sync.change_events e join eligible u on u.id = e.user_id
        group by e.user_id
        union all
        select r.user_id,
               pg_catalog.sum(pg_catalog.pg_column_size(r.request)::bigint
                              + pg_catalog.pg_column_size(r.response)), 'receipts'
        from pintheory_sync.mutation_receipts r join eligible u on u.id = r.user_id
        group by r.user_id
    ), per_user as (
        select p.user_id, pg_catalog.sum(p.bytes) as bytes
        from byte_parts p group by p.user_id
    ), user_totals as (
        select pg_catalog.count(*) as current_users,
               pg_catalog.count(*) filter (
                   where last_sign_in_at >= v_now - interval '30 days'
                     and last_sign_in_at <= v_now
               ) as active_users
        from eligible
    ), byte_totals as (
        select coalesce(pg_catalog.sum(bytes), 0) as total,
               coalesce(pg_catalog.sum(bytes) filter (where part = 'records'), 0) as records,
               coalesce(pg_catalog.sum(bytes) filter (where part = 'history'), 0) as history,
               coalesce(pg_catalog.sum(bytes) filter (where part = 'receipts'), 0) as receipts
        from byte_parts
    )
    select pg_catalog.jsonb_build_object(
        'schemaVersion', 1,
        'generatedAt', pg_catalog.to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'trackingStartedAt', pg_catalog.to_char(c.tracking_started_at at time zone 'UTC',
                                             'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'historyComplete', false,
        'users', pg_catalog.jsonb_build_object(
            'current', u.current_users::text,
            'active30d', u.active_users::text,
            'knownRegistrations', c.known_registrations::text,
            'knownDeletions', c.known_deletions::text
        ),
        'storage', pg_catalog.jsonb_build_object(
            'currentUserSyncBytes', b.total::bigint::text,
            'recordsBytes', b.records::bigint::text,
            'historyBytes', b.history::bigint::text,
            'receiptsBytes', b.receipts::bigint::text,
            'averageBytesPerUser', case when u.current_users = 0 then '0'
                else pg_catalog.ceil(b.total::numeric / u.current_users)::bigint::text end,
            'maxBytesPerUser', (select coalesce(pg_catalog.max(bytes), 0)::bigint::text from per_user),
            'syncPhysicalBytes', (
                pg_catalog.pg_total_relation_size('pintheory_sync.accounts'::pg_catalog.regclass)
                + pg_catalog.pg_total_relation_size('pintheory_sync.records'::pg_catalog.regclass)
                + pg_catalog.pg_total_relation_size('pintheory_sync.change_events'::pg_catalog.regclass)
                + pg_catalog.pg_total_relation_size('pintheory_sync.mutation_receipts'::pg_catalog.regclass)
            )::text,
            'databaseBytes', pg_catalog.pg_database_size(pg_catalog.current_database())::text,
            'objectStorageBytes', null
        ),
        'activityDefinition', 'signed_in_last_30_days'
    ) into strict v_result
    from pintheory_admin.account_counters c cross join user_totals u cross join byte_totals b
    where c.singleton;
    return v_result;
end;
$$;
alter function public.pintheory_admin_account_metrics() owner to postgres;

-- Logical: JSONB column sizes only, including tombstones; no row/index overhead.
-- Average denominator includes ALL current users, even those with zero sync data.
-- Physical: all four sync relations incl. indexes/TOAST, not just current users.
-- Database: whole project database, NOT user-only; never add physical to logical.
-- Object storage: unknown actual provider bytes, deliberately JSON null.
-- Activity: literal Auth sign-in proxy, NOT app usage or token refresh. Banned
-- users remain included; no inference of actual engagement is made.
-- INSERT of an already-soft-deleted identity records a registration only; the
-- baseline includes existing soft deletions, and future deletions count transitions.
comment on function public.pintheory_admin_account_metrics() is
    'Service-only aggregate lower-bound account history; Auth sign-in proxy; logical current-user JSONB sizes separate from whole-sync physical and whole-database bytes; object storage unknown.';

revoke all on all tables in schema pintheory_admin from public, anon, authenticated, service_role;
revoke all on all functions in schema pintheory_admin from public, anon, authenticated, service_role;
revoke all on all sequences in schema pintheory_admin from public, anon, authenticated, service_role;
revoke all on function public.pintheory_admin_account_metrics() from public, anon, authenticated, service_role;
grant execute on function public.pintheory_admin_account_metrics() to service_role;

commit;