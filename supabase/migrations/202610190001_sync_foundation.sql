-- Phase 1, NOT deployed. Execute manually as the trusted migration owner.
-- Deliberately not rerunnable: a failed transaction rolls back; an applied migration
-- must be changed by a reviewed forward migration, never by dropping user data.
begin;

create schema pintheory_sync;
revoke all on schema pintheory_sync from public, anon, authenticated, service_role;
alter default privileges in schema pintheory_sync revoke execute on functions from public;
alter default privileges in schema pintheory_sync revoke all on tables from anon, authenticated, service_role;

-- Shared exact-decimal domain with AccountSyncWire.JSONValue. No float casts:
-- <= 10^20 magnitude and <= 16 fractional places fit Swift Decimal exactly.
-- Equality ignores trailing zeros and exponent spelling. Booleans are not numbers.
create function pintheory_sync.payload_numbers_valid(p_value jsonb)
returns boolean language plpgsql immutable strict set search_path = pg_catalog as $$
declare
    v_number numeric;
    v_child jsonb;
begin
    case pg_catalog.jsonb_typeof(p_value)
    when 'number' then
        v_number := p_value::text::numeric;
        return pg_catalog.abs(v_number) <= 100000000000000000000::numeric
            and v_number = pg_catalog.round(v_number, 16);
    when 'array' then
        for v_child in select value from pg_catalog.jsonb_array_elements(p_value) loop
            if not pintheory_sync.payload_numbers_valid(v_child) then return false; end if;
        end loop;
    when 'object' then
        for v_child in select value from pg_catalog.jsonb_each(p_value) loop
            if not pintheory_sync.payload_numbers_valid(v_child) then return false; end if;
        end loop;
    else
        null;
    end case;
    return true;
end;
$$;

create table pintheory_sync.accounts (
    user_id uuid primary key references auth.users(id) on delete cascade,
    state text not null default 'active' check (state in ('active', 'deleting', 'blocked')),
    last_sequence bigint not null default 0 check (last_sequence >= 0),
    created_at timestamptz not null default pg_catalog.clock_timestamp()
);

create table pintheory_sync.records (
    user_id uuid not null references pintheory_sync.accounts(user_id) on delete cascade,
    record_id uuid not null,
    kind text not null check (kind in (
        'golfer_profile', 'club_profile', 'wedge', 'custom_club', 'custom_course',
        'custom_tee', 'played_round', 'handicap_round', 'flag_position'
    )),
    schema_version integer not null check (schema_version = 1),
    payload jsonb not null check (
        pg_catalog.jsonb_typeof(payload) = 'object'
        and pg_catalog.octet_length(payload::text) <= 65536
        and pintheory_sync.payload_numbers_valid(payload)
    ),
    source_saved_round_id uuid,
    revision bigint not null check (revision > 0),
    created_at timestamptz not null,
    updated_at timestamptz not null,
    deleted_at timestamptz,
    primary key (user_id, record_id),
    check (source_saved_round_id is null or kind = 'handicap_round')
);

-- Includes tombstones: deleting an imported HCP entry does not allow a second
-- identity to silently reimport the same saved round. Restore the original ID.
create unique index records_handicap_source_unique
    on pintheory_sync.records(user_id, source_saved_round_id)
    where kind = 'handicap_round' and source_saved_round_id is not null;

create table pintheory_sync.change_events (
    user_id uuid not null references pintheory_sync.accounts(user_id) on delete cascade,
    sequence bigint not null check (sequence > 0),
    record jsonb not null check (pg_catalog.jsonb_typeof(record) = 'object'),
    primary key (user_id, sequence)
);

create table pintheory_sync.mutation_receipts (
    user_id uuid not null references pintheory_sync.accounts(user_id) on delete cascade,
    mutation_id uuid not null,
    request jsonb not null,
    response jsonb not null,
    created_at timestamptz not null default pg_catalog.clock_timestamp(),
    primary key (user_id, mutation_id)
);

create function pintheory_sync.reject_history_change()
returns trigger language plpgsql set search_path = pg_catalog as $$
begin
    raise exception using errcode = '55000', message = 'sync_history_is_immutable';
end;
$$;

create trigger immutable_change_events before update or delete
    on pintheory_sync.change_events for each row
    execute function pintheory_sync.reject_history_change();
create trigger immutable_mutation_receipts before update or delete
    on pintheory_sync.mutation_receipts for each row
    execute function pintheory_sync.reject_history_change();
-- TRUNCATE is not granted to API roles. Privileged lifecycle cleanup must be
-- separately reviewed; these triggers intentionally also block cascading purge.

alter table pintheory_sync.accounts enable row level security;
alter table pintheory_sync.records enable row level security;
alter table pintheory_sync.change_events enable row level security;
alter table pintheory_sync.mutation_receipts enable row level security;
create policy accounts_owner_read on pintheory_sync.accounts
    for select to authenticated using (user_id = (select auth.uid()));
create policy records_owner_read on pintheory_sync.records
    for select to authenticated using (user_id = (select auth.uid()));
create policy events_owner_read on pintheory_sync.change_events
    for select to authenticated using (user_id = (select auth.uid()));
create policy receipts_owner_read on pintheory_sync.mutation_receipts
    for select to authenticated using (user_id = (select auth.uid()));
-- No API write policies, schema usage, or direct table grants. RLS is defense in
-- depth; the trusted function owner bypasses RLS and must enforce UID explicitly.

create function pintheory_sync.record_wire(p_record pintheory_sync.records)
returns jsonb language sql stable set search_path = pg_catalog as $$
    select pg_catalog.jsonb_build_object(
        'record_id', p_record.record_id, 'kind', p_record.kind,
        'schema_version', p_record.schema_version, 'payload', p_record.payload,
        'revision', p_record.revision::text,
        'created_at', p_record.created_at, 'updated_at', p_record.updated_at,
        'deleted_at', p_record.deleted_at
    );
$$;

create function public.pintheory_sync_mutate(
    p_mutation_id uuid,
    p_record_id uuid,
    p_kind text,
    p_expected_revision text,
    p_operation text,
    p_schema_version integer,
    p_payload jsonb
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_uid uuid := auth.uid();
    v_account pintheory_sync.accounts%rowtype;
    v_record pintheory_sync.records%rowtype;
    v_source_record pintheory_sync.records%rowtype;
    v_receipt pintheory_sync.mutation_receipts%rowtype;
    v_request jsonb;
    v_response jsonb;
    v_expected bigint;
    v_source uuid;
    v_sequence bigint;
    v_now timestamptz;
    v_exists boolean;
begin
    if v_uid is null then
        raise exception using errcode = '28000', message = 'authentication_required';
    end if;
    if p_mutation_id is null or p_record_id is null or p_kind is null
       or p_kind not in ('golfer_profile', 'club_profile', 'wedge', 'custom_club',
           'custom_course', 'custom_tee', 'played_round', 'handicap_round', 'flag_position')
       or p_operation is null or p_operation not in ('put', 'delete')
       or p_schema_version is distinct from 1
       or p_expected_revision is null or p_expected_revision !~ '^(0|[1-9][0-9]{0,18})$'
       or p_payload is null or pg_catalog.jsonb_typeof(p_payload) <> 'object'
       or pg_catalog.octet_length(p_payload::text) > 65536 then
        raise exception using errcode = '22023', message = 'invalid_sync_request';
    end if;
        -- Reject before account/receipt/event writes, including losing CAS requests.
        if not pintheory_sync.payload_numbers_valid(p_payload) then
            raise exception using errcode = '22023', message = 'invalid_payload_number';
        end if;
    -- Out-of-range bigint is an error, never coerced via a floating point number.
    v_expected := p_expected_revision::bigint;
    if p_operation = 'delete' and p_payload <> '{}'::jsonb then
        raise exception using errcode = '22023', message = 'delete_payload_must_be_empty';
    end if;
    if p_payload ? 'sourceSavedRoundID' then
        if p_kind <> 'handicap_round' then
            raise exception using errcode = '22023', message = 'source_link_only_for_handicap_round';
        end if;
        if p_payload->'sourceSavedRoundID' <> 'null'::jsonb then
            if pg_catalog.jsonb_typeof(p_payload->'sourceSavedRoundID') <> 'string'
               or (p_payload->>'sourceSavedRoundID') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
                raise exception using errcode = '22023', message = 'invalid_source_saved_round_id';
            end if;
            v_source := (p_payload->>'sourceSavedRoundID')::uuid;
        end if;
    end if;
    v_request := pg_catalog.jsonb_build_object(
        'record_id', p_record_id, 'kind', p_kind, 'expected_revision', p_expected_revision,
        'operation', p_operation, 'schema_version', p_schema_version, 'payload', p_payload
    );

    -- The auth.users FK prevents a stale JWT recreating a removed auth identity.
    insert into pintheory_sync.accounts(user_id) values (v_uid) on conflict do nothing;
    select a.* into strict v_account from pintheory_sync.accounts a
        where a.user_id = v_uid for update;
    -- ALL writes for one UID serialize here, including receipt lookup. A trusted
    -- lifecycle UPDATE of this row takes the same lock and linearizes blocking.
    if v_account.state <> 'active' then
        raise exception using errcode = '42501', message = 'account_not_active';
    end if;
    select r.* into v_receipt from pintheory_sync.mutation_receipts r
        where r.user_id = v_uid and r.mutation_id = p_mutation_id;
    if found then
        if v_receipt.request <> v_request then
            raise exception using errcode = '22023', message = 'mutation_id_reused_with_different_request';
        end if;
        return v_receipt.response;
    end if;

    select r.* into v_record from pintheory_sync.records r
        where r.user_id = v_uid and r.record_id = p_record_id;
    v_exists := found;
    if (v_exists and (v_record.revision <> v_expected or v_record.kind <> p_kind))
       or (not v_exists and (v_expected <> 0 or p_operation = 'delete')) then
        v_response := pg_catalog.jsonb_build_object(
            'status', 'conflict', 'mutation_id', p_mutation_id,
            'current', case when v_exists then pintheory_sync.record_wire(v_record) else null end
        );
    else
        if p_operation = 'put' and v_source is not null then
            select r.* into v_source_record from pintheory_sync.records r
                where r.user_id = v_uid and r.kind = 'handicap_round'
                  and r.source_saved_round_id = v_source and r.record_id <> p_record_id;
            if found then
                v_response := pg_catalog.jsonb_build_object(
                    'status', 'source_conflict', 'mutation_id', p_mutation_id,
                    'current', case when v_exists then pintheory_sync.record_wire(v_record) else null end,
                    'source_record', pintheory_sync.record_wire(v_source_record)
                );
            end if;
        end if;
        if v_response is null then
            v_sequence := v_account.last_sequence + 1;
            v_now := pg_catalog.clock_timestamp();
            if p_operation = 'delete' then
                update pintheory_sync.records r set revision = v_sequence,
                    updated_at = v_now, deleted_at = v_now
                    where r.user_id = v_uid and r.record_id = p_record_id returning r.* into v_record;
            else
                insert into pintheory_sync.records as r (
                    user_id, record_id, kind, schema_version, payload, source_saved_round_id,
                    revision, created_at, updated_at, deleted_at
                ) values (v_uid, p_record_id, p_kind, 1, p_payload, v_source,
                    v_sequence, v_now, v_now, null)
                on conflict (user_id, record_id) do update set
                    payload = excluded.payload, source_saved_round_id = excluded.source_saved_round_id,
                    revision = excluded.revision, updated_at = excluded.updated_at, deleted_at = null
                returning r.* into v_record;
            end if;
            update pintheory_sync.accounts set last_sequence = v_sequence where user_id = v_uid;
            insert into pintheory_sync.change_events(user_id, sequence, record)
                values (v_uid, v_sequence, pintheory_sync.record_wire(v_record));
            v_response := pg_catalog.jsonb_build_object(
                'status', 'applied', 'mutation_id', p_mutation_id,
                'record', pintheory_sync.record_wire(v_record)
            );
        end if;
    end if;
    -- Both rejected CAS requests and accepted mutations are durably replayable.
    insert into pintheory_sync.mutation_receipts(user_id, mutation_id, request, response)
        values (v_uid, p_mutation_id, v_request, v_response);
    return v_response;
end;
$$;

create function public.pintheory_sync_changes(
    p_after text default '0',
    p_through text default null,
    p_limit integer default 100
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
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
    -- Lazy opening also verifies an extant auth.users row before an empty pull.
    insert into pintheory_sync.accounts(user_id) values (v_uid) on conflict do nothing;
    select a.* into strict v_account from pintheory_sync.accounts a where a.user_id = v_uid;
    if v_account.state <> 'active' then
        raise exception using errcode = '42501', message = 'account_not_active';
    end if;
    v_through := coalesce(p_through::bigint, v_account.last_sequence);
    if v_after > v_through or v_through > v_account.last_sequence then
        raise exception using errcode = '22023', message = 'invalid_change_cursor';
    end if;
    -- High-water mark is captured BEFORE reading immutable events. Any later
    -- commit has a greater sequence and cannot change this bounded page set.
    select coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('sequence', e.sequence::text, 'record', e.record)
        order by e.sequence), '[]'::jsonb), coalesce(max(e.sequence), v_after)
    into v_events, v_next
    from (
        select c.sequence, c.record from pintheory_sync.change_events c
        where c.user_id = v_uid and c.sequence > v_after and c.sequence <= v_through
        order by c.sequence limit p_limit
    ) e;
    return pg_catalog.jsonb_build_object(
        'events', v_events, 'next_after', v_next::text,
        'through', v_through::text, 'has_more', v_next < v_through
    );
end;
$$;

revoke all on all tables in schema pintheory_sync from public, anon, authenticated, service_role;
revoke all on all functions in schema pintheory_sync from public, anon, authenticated, service_role;
revoke all on function public.pintheory_sync_mutate(uuid, uuid, text, text, text, integer, jsonb)
    from public, anon, authenticated, service_role;
revoke all on function public.pintheory_sync_changes(text, text, integer)
    from public, anon, authenticated, service_role;
grant execute on function public.pintheory_sync_mutate(uuid, uuid, text, text, text, integer, jsonb)
    to authenticated;
grant execute on function public.pintheory_sync_changes(text, text, integer) to authenticated;

commit;