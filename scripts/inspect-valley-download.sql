-- Run in the intended Supabase project's SQL Editor as the database owner.
-- Read-only: no provider calls, job resets, tokens, credentials, or user data.
begin read only;

-- Find Valley's actual provider ID in already-cached Hills search results.
with valley as (
    select distinct course->>'courseID' as course_id,
        club->>'clubName' as club_name, course->>'courseName' as course_name,
        course->>'hasGPS' as reported_gps
    from pintheory_data.responses r
    cross join lateral jsonb_array_elements(
        case when jsonb_typeof(r.body->'clubs') = 'array' then r.body->'clubs' else '[]'::jsonb end
    ) club
    cross join lateral jsonb_array_elements(
        case when jsonb_typeof(club->'courses') = 'array' then club->'courses' else '[]'::jsonb end
    ) course
    where r.provider = 'golf' and r.key like 'golf:v1:clubs:%'
      and club->>'clubName' ilike '%hills%'
      and course->>'courseName' ilike '%valley%'
), requested_keys as (
    select v.*, 'golf:v1:' || kind || ':' || course_id as cache_key
    from valley v cross join (values ('detail'), ('coordinates')) kinds(kind)
)
select k.club_name, k.course_name, k.course_id, k.reported_gps, k.cache_key,
    r.key is not null as response_cached, r.fetched_at,
    j.state as job_state, j.until as job_deadline,
    j.state = 'dispatched' and j.until <= now() as uncertain_job_blocked
from requested_keys k
left join pintheory_data.responses r on r.key = k.cache_key
left join pintheory_data.jobs j on j.key = k.cache_key
order by k.course_id, k.cache_key;

-- Provider gates only. Does not reset budgets or clear cooldowns.
select provider, enabled, daily_limit, cooldown_until
from pintheory_data.settings where provider = 'golf';

commit;