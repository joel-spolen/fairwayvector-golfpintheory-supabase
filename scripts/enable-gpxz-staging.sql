-- DISPOSABLE STAGING ONLY. Never run on production: GPXZ's free plan is for testing,
-- and production must stay disabled until a paid plan and terms review are done.
-- Run manually as postgres with psql -X -v ON_ERROR_STOP=1 after 202611010001.
-- A whole-course raster is one GPXZ request per ≤2500 m tile; 80/day leaves headroom under the free plan's 100.
begin;

update pintheory_data.settings set enabled = true, daily_limit = 80 where provider = 'gpxz';
select provider, enabled, daily_limit, cooldown_until from pintheory_data.settings where provider = 'gpxz';

commit;
