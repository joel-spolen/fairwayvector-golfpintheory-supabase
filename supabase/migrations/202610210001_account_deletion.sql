-- Account deletion workflow. Apply AFTER 202610190001_sync_foundation.sql.
-- Forward-only; source reviewed, not deployed or database-tested.
-- This migration assumes Supabase's trusted migration owner is postgres.
begin;

-- Deletion is a state transition serialized by the same account-row lock used
-- by mutations. A recent JWT iat is required only for active -> deleting.
create function public.pintheory_begin_account_deletion()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_uid uuid := auth.uid();
    v_account pintheory_sync.accounts%rowtype;
    v_iat_text text;
    v_iat numeric;
    v_now numeric := pg_catalog.date_part('epoch', pg_catalog.clock_timestamp());
begin
    if v_uid is null then
        raise exception using errcode = '28000', message = 'authentication_required';
    end if;

    -- The FK rejects stale sessions whose Auth identity has already been removed.
    insert into pintheory_sync.accounts(user_id) values (v_uid) on conflict do nothing;
    select a.* into strict v_account
    from pintheory_sync.accounts a
    where a.user_id = v_uid
    for update;

    if v_account.state = 'deleting' then
        return pg_catalog.jsonb_build_object('status', 'deleting');
    end if;
    if v_account.state <> 'active' then
        raise exception using errcode = '42501', message = 'account_deletion_not_allowed';
    end if;

    v_iat_text := auth.jwt()->>'iat';
    if v_iat_text is null or v_iat_text !~ '^[0-9]{1,12}$' then
        raise exception using errcode = '42501', message = 'recent_authentication_required';
    end if;
    v_iat := v_iat_text::numeric;
    if v_iat > v_now or v_iat < v_now - 600 then
        raise exception using errcode = '42501', message = 'recent_authentication_required';
    end if;

    update pintheory_sync.accounts
    set state = 'deleting'
    where user_id = v_uid;

    return pg_catalog.jsonb_build_object('status', 'deleting');
end;
$$;
alter function public.pintheory_begin_account_deletion() owner to postgres;

-- Replace only the locking behavior: a pull holds a shared row lock through its
-- bounded read, so the deletion transition waits for in-flight sync RPCs. Once
-- deletion owns the row, all later pulls observe deleting and fail closed.
create or replace function public.pintheory_sync_changes(
    p_after text default '0',
    p_through text default null,
    p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_uid uuid := auth.uid();
    v_account pintheory_sync.accounts%rowtype;
    v_after bigint;
    v_through bigint;
    v_next bigint;
    v_events jsonb;
begin
    if v_uid is null then
        raise exception using errcode = '28000', message = 'authentication_required';
    end if;
    if p_after is null or p_after !~ '^(0|[1-9][0-9]{0,18})$'
       or (p_through is not null and p_through !~ '^(0|[1-9][0-9]{0,18})$')
       or p_limit is null or p_limit < 1 or p_limit > 200 then
        raise exception using errcode = '22023', message = 'invalid_change_cursor';
    end if;
    v_after := p_after::bigint;
    insert into pintheory_sync.accounts(user_id) values (v_uid) on conflict do nothing;
    select a.* into strict v_account
    from pintheory_sync.accounts a
    where a.user_id = v_uid
    for share;
    if v_account.state <> 'active' then
        raise exception using errcode = '42501', message = 'account_not_active';
    end if;
    v_through := coalesce(p_through::bigint, v_account.last_sequence);
    if v_after > v_through or v_through > v_account.last_sequence then
        raise exception using errcode = '22023', message = 'invalid_change_cursor';
    end if;
    select coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('sequence', e.sequence::text, 'record', e.record)
        order by e.sequence), '[]'::jsonb), coalesce(max(e.sequence), v_after)
    into v_events, v_next
    from (
        select c.sequence, c.record
        from pintheory_sync.change_events c
        where c.user_id = v_uid and c.sequence > v_after and c.sequence <= v_through
        order by c.sequence
        limit p_limit
    ) e;
    return pg_catalog.jsonb_build_object(
        'events', v_events,
        'next_after', v_next::text,
        'through', v_through::text,
        'has_more', v_next < v_through
    );
end;
$$;
alter function public.pintheory_sync_changes(text, text, integer) owner to postgres;

-- Immutable-history DELETE is allowed only while the trusted postgres-owned
-- purge routine is running and its transaction-local UID matches OLD.user_id.
create or replace function pintheory_sync.reject_history_change()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
    if tg_op = 'DELETE'
       and current_user = 'postgres'
       and pg_catalog.current_setting('pintheory.purge_uid', true) = old.user_id::text then
        return old;
    end if;
    raise exception using errcode = '55000', message = 'sync_history_is_immutable';
end;
$$;
alter function pintheory_sync.reject_history_change() owner to postgres;

-- Internal erasure primitive. It deliberately leaves the deleting account row
-- in place so no authenticated RPC can lazily recreate an active account.
create function pintheory_sync.purge_account_data(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_account pintheory_sync.accounts%rowtype;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception using errcode = '42501', message = 'service_role_required';
    end if;
    if p_user_id is null then
        raise exception using errcode = '22023', message = 'user_id_required';
    end if;

    select a.* into v_account
    from pintheory_sync.accounts a
    where a.user_id = p_user_id
    for update;
    if not found or v_account.state <> 'deleting' then
        raise exception using errcode = '42501', message = 'account_not_deleting';
    end if;

    perform pg_catalog.set_config('pintheory.purge_uid', p_user_id::text, true);
    delete from pintheory_sync.records where user_id = p_user_id;
    delete from pintheory_sync.change_events where user_id = p_user_id;
    delete from pintheory_sync.mutation_receipts where user_id = p_user_id;
    perform pg_catalog.set_config('pintheory.purge_uid', '', true);

    return pg_catalog.jsonb_build_object('status', 'purged');
end;
$$;
alter function pintheory_sync.purge_account_data(uuid) owner to postgres;

-- PostgREST cannot call the unexposed private schema. This service-role-only
-- public RPC is a narrow bridge to the private purge primitive for the Edge
-- Function; the private schema remains unexposed and has no API-role usage.
create function public.pintheory_purge_account(p_user_id uuid)
returns jsonb
language sql
security definer
set search_path = pg_catalog
as $$
    select pintheory_sync.purge_account_data(p_user_id);
$$;
alter function public.pintheory_purge_account(uuid) owner to postgres;

revoke all on function public.pintheory_begin_account_deletion() from public, anon, authenticated, service_role;
grant execute on function public.pintheory_begin_account_deletion() to authenticated;
revoke all on function pintheory_sync.purge_account_data(uuid) from public, anon, authenticated, service_role;
grant execute on function pintheory_sync.purge_account_data(uuid) to service_role;
revoke all on function public.pintheory_purge_account(uuid) from public, anon, authenticated, service_role;
grant execute on function public.pintheory_purge_account(uuid) to service_role;

commit;