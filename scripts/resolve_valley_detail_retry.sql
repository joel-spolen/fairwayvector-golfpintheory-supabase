-- ONE-TIME OPERATOR ACTION. Run only in the intended Supabase project's SQL Editor
-- as the trusted database owner, after confirming operator authorization.
-- This does not call GolfAPI, clear provider cooldowns, reset budgets or affect coordinates.
-- It permits one future claim for Valley's uncertain COURSE-DETAIL key only.
begin;

-- The admin RPC requires service_role. This transaction-local claim is set only
-- inside the trusted SQL Editor session; it is not stored in the database.
select pg_catalog.set_config('request.jwt.claim.role', 'service_role', true);

do $$
declare
    v_key constant text := 'golf:v1:detail:0121690712297913687';
    v_resolved boolean;
begin
    if exists (select 1 from pintheory_data.responses where key = v_key) then
        raise exception 'Valley details are already cached; no resolution performed';
    end if;
    if not exists (select 1 from pintheory_data.jobs
        where key = v_key and state = 'dispatched' and until <= pg_catalog.clock_timestamp()) then
        raise exception 'Valley detail job is not an expired ambiguous dispatch; no resolution performed';
    end if;
    v_resolved := public.pintheory_data_admin_resolve(v_key, 'ALLOW_PAID_RETRY');
    if not v_resolved then
        raise exception 'Valley detail resolution was not applied';
    end if;
    raise notice 'Resolved only the expired Valley detail job. No provider request was sent.';
end;
$$;

commit;
