-- Enable the user's approved GolfAPI course search/download path only.
-- Provider secrets live in Edge secrets, never SQL. No HTTP occurs here.
-- Keep existing daily limits, usage, cooldowns and uncertain-job fences intact.
-- GPXZ settings are deliberately unchanged.
begin;

do $$
begin
    if pg_catalog.to_regclass('pintheory_data.settings') is null then
        raise exception 'shared data cache migration is required before GolfAPI activation';
    end if;
    if not exists (select 1 from pintheory_data.settings where provider = 'golf') then
        raise exception 'GolfAPI provider settings are missing';
    end if;
end;
$$;

update pintheory_data.settings set enabled = true where provider = 'golf';

commit;