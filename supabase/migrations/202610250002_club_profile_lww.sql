-- Add timestamp-aware last-write-wins conflict resolution for trajectory club profiles.
-- Apply after 202610250001_sync_club_profile.sql.
begin;

-- Preserve the strict v2 club-profile DTO validator, while allowing one validated
-- metadata field. Historical records without this field remain valid and use the
-- database updated_at timestamp as their legacy comparison time.
create or replace function pintheory_sync.approved_payload_valid(p_kind text, p jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare
    v_client_updated_at timestamptz;
begin
    if p_kind not in ('club_profile', 'wedge') then
        return pintheory_sync.payload_valid(p_kind, p);
    end if;
    if p ? 'clientUpdatedAt' and (
       pg_catalog.jsonb_typeof(p->'clientUpdatedAt') is distinct from 'string'
       or not pintheory_sync.string_valid(p->'clientUpdatedAt', 20, 40)) then
        return false;
    end if;
    if p ? 'clientUpdatedAt' then
        begin
            v_client_updated_at := (p->>'clientUpdatedAt')::timestamptz;
        exception when others then
            return false;
        end;
        if not pg_catalog.isfinite(v_client_updated_at) then return false; end if;
        if p_kind = 'club_profile' then
            return pintheory_sync.club_profile_payload_valid(p - 'clientUpdatedAt');
        end if;
        return pintheory_sync.payload_valid(p_kind, p - 'clientUpdatedAt');
    end if;
    if p_kind = 'club_profile' then
        return pintheory_sync.club_profile_payload_valid(p);
    end if;
    return pintheory_sync.payload_valid(p_kind, p);
exception when others then
    return false;
end;
$$;

-- The function is security-internal; preserve the existing owner/grants policy.
alter function pintheory_sync.approved_payload_valid(text, jsonb) owner to postgres;
revoke all on function pintheory_sync.approved_payload_valid(text, jsonb)
    from public, anon, authenticated, service_role;

-- Recheck current rows/immutable events/receipts against the expanded contract.
do $$
begin
    if exists (select 1 from pintheory_sync.records r
        where not pintheory_sync.approved_payload_valid(r.kind, r.payload)) then
        raise exception 'existing sync records fail the timestamp-aware DTO contract';
    end if;
    if exists (select 1 from pintheory_sync.change_events e
        where not pintheory_sync.record_payload_valid(e.record)) then
        raise exception 'existing sync events fail the timestamp-aware DTO contract';
    end if;
    if exists (select 1 from pintheory_sync.mutation_receipts r
        where not pintheory_sync.receipt_payloads_valid(pg_catalog.jsonb_build_object(
            'mutation_id', r.mutation_id, 'request', r.request, 'response', r.response))) then
        raise exception 'existing sync receipts fail the timestamp-aware DTO contract';
    end if;
end;
$$;

create or replace function public.pintheory_sync_capabilities()
returns jsonb language sql stable security definer set search_path = pg_catalog as $$
    select pg_catalog.jsonb_build_object(
        'sync_schema_version', 1,
        'payload_validation_version', 3
    );
$$;
alter function public.pintheory_sync_capabilities() owner to postgres;
revoke all on function public.pintheory_sync_capabilities() from public, anon, authenticated, service_role;
grant execute on function public.pintheory_sync_capabilities() to authenticated;

commit;
