// Catalog-only comparison. Never executes migration SQL or application RPCs.
// Usage: node scripts/verify-existing-sync.mjs --project-ref <approved-project>
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Explicit structural baseline transcribed from CREATE TABLE/ALTER TABLE in
// these three files; never inferred from the target being inspected.
const tableBaseline = {
  accounts: {
    columns: [['user_id','uuid',true,null],['state','text',true,"'active'::text"],['last_sequence','bigint',true,'0'],['created_at','timestamp with time zone',true,'clock_timestamp()']],
    checks: { accounts_last_sequence_check: 'CHECK (last_sequence >= 0)', accounts_state_check: "CHECK (state = ANY (ARRAY['active'::text, 'deleting'::text, 'blocked'::text]))" },
    primary: 'user_id', foreign: 'auth.users(id)', policy: 'accounts_owner_read'
  },
  records: {
    columns: [['user_id','uuid',true,null],['record_id','uuid',true,null],['kind','text',true,null],['schema_version','integer',true,null],['payload','jsonb',true,null],['source_saved_round_id','uuid',false,null],['revision','bigint',true,null],['created_at','timestamp with time zone',true,null],['updated_at','timestamp with time zone',true,null],['deleted_at','timestamp with time zone',false,null]],
    checks: {
      records_check: "CHECK (source_saved_round_id IS NULL OR kind = 'handicap_round'::text)",
      records_domain_payload_valid: 'CHECK (pintheory_sync.payload_valid(kind, payload))',
      records_kind_check: "CHECK (kind = ANY (ARRAY['golfer_profile'::text, 'club_profile'::text, 'wedge'::text, 'custom_club'::text, 'custom_course'::text, 'custom_tee'::text, 'played_round'::text, 'handicap_round'::text, 'flag_position'::text]))",
      records_payload_check: "CHECK (jsonb_typeof(payload) = 'object'::text AND octet_length(payload::text) <= 65536 AND pintheory_sync.payload_numbers_valid(payload))",
      records_revision_check: 'CHECK (revision > 0)', records_schema_version_check: 'CHECK (schema_version = 1)'
    },
    primary: 'user_id, record_id', foreign: 'pintheory_sync.accounts(user_id)', policy: 'records_owner_read'
  },
  change_events: {
    columns: [['user_id','uuid',true,null],['sequence','bigint',true,null],['record','jsonb',true,null]],
    checks: { change_events_domain_payload_valid: 'CHECK (pintheory_sync.record_payload_valid(record))', change_events_record_check: "CHECK (jsonb_typeof(record) = 'object'::text)", change_events_sequence_check: 'CHECK (sequence > 0)' },
    primary: 'user_id, sequence', foreign: 'pintheory_sync.accounts(user_id)', policy: 'events_owner_read'
  },
  mutation_receipts: {
    columns: [['user_id','uuid',true,null],['mutation_id','uuid',true,null],['request','jsonb',true,null],['response','jsonb',true,null],['created_at','timestamp with time zone',true,'clock_timestamp()']],
    checks: {}, primary: 'user_id, mutation_id', foreign: 'pintheory_sync.accounts(user_id)', policy: 'receipts_owner_read'
  }
};
const root = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--project-ref' || !/^[a-z]{20}$/.test(args[1])) {
  throw new Error('Supply exactly --project-ref <approved-project>; no implicit target.');
}
const project = args[1];
const files = [
  '202610190001_sync_foundation.sql',
  '202610210001_account_deletion.sql',
  '202610230001_sync_domain_validation.sql'
];
const functions = new Map();
const migrations = [];
for (const file of files) {
  const sql = readFileSync(new URL(`../supabase/migrations/${file}`, import.meta.url), 'utf8');
  migrations.push({ file, sha256: createHash('sha256').update(sql).digest('hex') });
  const pattern = /create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\(([^]*?)\)\s*(returns\b[^]*?)\bas\s*\$\$([^]*?)\$\$\s*;/gi;
  let count = 0;
  for (const match of sql.matchAll(pattern)) {
    const [, name, parameters, attributes, body] = match;
    const types = parameters.trim() ? parameters.split(',').map(p =>
      p.trim().replace(/^\w+\s+/, '').replace(/\s+default\b[^]*/i, '').trim()) : [];
    const signature = `${name}(${types.join(',')})`;
    functions.set(signature, { signature, parameters: parameters.trim(), attributes: attributes.trim(), body, file });
    count++;
  }
  const declared = [...sql.matchAll(/create\s+(?:or\s+replace\s+)?function\b/gi)].length;
  if (count !== declared) throw new Error(`Incomplete function extraction for ${file}`);
}
if (functions.size !== 21) throw new Error(`Unexpected baseline function count: ${functions.size}`);
const literal = value => `'${value.replaceAll("'", "''")}'`;
function query(sql) {
  // Every request is a READ ONLY transaction. Only generated catalog SELECTs
  // are sent; migration source occurs exclusively as SQL string literals.
  const output = execFileSync('supabase', ['db', 'query', '--linked', '--project-ref', project,
    '--output', 'json', `begin read only; ${sql}; commit;`], {
    cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'inherit']
  });
  const parsed = JSON.parse(output);
  if (!Array.isArray(parsed.rows)) throw new Error('Unexpected CLI JSON result');
  return parsed.rows;
}
const presence = query(`select current_setting('transaction_read_only') as read_only,
  to_regclass('supabase_migrations.schema_migrations')::text as migration_history,
  to_regclass('pintheory_data.settings')::text as data_settings,
  to_regnamespace('pintheory_data')::text as data_schema,
  to_regnamespace('pintheory_admin')::text as admin_schema`)[0];
const expected = [...functions.values()];
const values = expected.map(f => `(${literal(f.signature)},${literal(f.body)})`).join(',\n');
const rows = query(`with expected(signature, body) as (values ${values}),
  target as (select p.*, n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='pintheory_sync' or (n.nspname='public' and p.proname like 'pintheory_%'))
select jsonb_build_object(
  'read_only', current_setting('transaction_read_only'),
  'functions', (select jsonb_agg(jsonb_build_object(
    'signature', e.signature, 'present', p.oid is not null,
    'arguments', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
    'owner', pg_get_userbyid(p.proowner), 'language', l.lanname,
    'security_definer', p.prosecdef, 'strict', p.proisstrict, 'volatility', p.provolatile,
    'parallel', p.proparallel, 'kind', p.prokind, 'config', p.proconfig,
    'acl', p.proacl::text,
    'acl_entries', (select jsonb_agg(jsonb_build_object('grantee', case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,
       'grantor', pg_get_userbyid(a.grantor), 'privilege', a.privilege_type, 'grantable', a.is_grantable) order by a.grantee, a.privilege_type)
       from aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) a),
    'effective_api_execute', (select jsonb_object_agg(r.rolname,has_function_privilege(r.oid,p.oid,'EXECUTE'))
       from pg_roles r where r.rolname in ('anon','authenticated','service_role')),
    'expected_raw_md5', md5(e.body), 'remote_raw_md5', md5(p.prosrc),
    'expected_whitespace_md5', md5(regexp_replace(e.body,'[[:space:]]','','g')),
    'remote_whitespace_md5', md5(regexp_replace(p.prosrc,'[[:space:]]','','g')),
    'raw_equal', e.body=p.prosrc,
    'whitespace_equal', regexp_replace(e.body,'[[:space:]]','','g')=regexp_replace(p.prosrc,'[[:space:]]','','g'),
    'remote_body_if_different', case when e.body is distinct from p.prosrc then p.prosrc end
  ) order by e.signature) from expected e left join pg_proc p on p.oid=to_regprocedure(e.signature)
    left join pg_language l on l.oid=p.prolang),
  'extra_functions', (select coalesce(jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,
    'owner',pg_get_userbyid(p.proowner),'definition',pg_get_functiondef(p.oid)) order by p.oid::regprocedure::text),'[]')
    from target p where not exists (select 1 from expected e where to_regprocedure(e.signature)=p.oid)),
  'schemas', (select jsonb_agg(jsonb_build_object('name',n.nspname,'owner',pg_get_userbyid(n.nspowner),'acl',n.nspacl::text,
    'effective_api', (select jsonb_object_agg(r.rolname,jsonb_build_object('usage',has_schema_privilege(r.oid,n.oid,'USAGE'),
      'create',has_schema_privilege(r.oid,n.oid,'CREATE'))) from pg_roles r where r.rolname in ('anon','authenticated','service_role'))))
    from pg_namespace n where n.nspname in ('pintheory_sync','pintheory_data','pintheory_admin')),
  'tables', (select jsonb_agg(jsonb_build_object('table',c.oid::regclass::text,'kind',c.relkind,
    'owner',pg_get_userbyid(c.relowner),'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,'acl',c.relacl::text,
    'effective_api', (select jsonb_object_agg(r.rolname,has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))
      from pg_roles r where r.rolname in ('anon','authenticated','service_role')),
    'columns', (select jsonb_agg(jsonb_build_object('position',a.attnum,'name',a.attname,
       'type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,'default',pg_get_expr(d.adbin,d.adrelid),
       'identity',a.attidentity,'generated',a.attgenerated,'acl',a.attacl::text,'collation',co.collname) order by a.attnum)
       from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
       left join pg_collation co on co.oid=a.attcollation where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped),
    'constraints', (select jsonb_agg(jsonb_build_object('name',k.conname,'type',k.contype,
       'definition',pg_get_constraintdef(k.oid,true),'validated',k.convalidated,'deferrable',k.condeferrable,
       'initially_deferred',k.condeferred) order by k.conname) from pg_constraint k where k.conrelid=c.oid),
    'indexes', (select jsonb_agg(jsonb_build_object('name',ic.relname,'definition',pg_get_indexdef(i.indexrelid),
       'valid',i.indisvalid,'ready',i.indisready,'unique',i.indisunique,'primary',i.indisprimary) order by ic.relname)
       from pg_index i join pg_class ic on ic.oid=i.indexrelid where i.indrelid=c.oid),
    'policies', (select jsonb_agg(jsonb_build_object('name',p.polname,'command',p.polcmd,'permissive',p.polpermissive,
       'roles',(select jsonb_agg(case when r=0 then 'PUBLIC' else pg_get_userbyid(r) end) from unnest(p.polroles) r),
       'using',pg_get_expr(p.polqual,p.polrelid),'check',pg_get_expr(p.polwithcheck,p.polrelid)) order by p.polname)
       from pg_policy p where p.polrelid=c.oid)
    ) order by c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace
       where n.nspname='pintheory_sync' and c.relkind in ('r','p','v','m','f')),
  'triggers', (select jsonb_agg(jsonb_build_object('table',t.tgrelid::regclass::text,'name',t.tgname,
     'enabled',t.tgenabled,'definition',pg_get_triggerdef(t.oid,true),'function',t.tgfoid::regprocedure::text)
     order by t.tgrelid::regclass::text,t.tgname) from pg_trigger t join pg_class c on c.oid=t.tgrelid
     join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and
       (n.nspname='pintheory_sync' or (n.nspname='auth' and c.relname='users'))),
  'default_acls', (select jsonb_agg(jsonb_build_object('owner',pg_get_userbyid(d.defaclrole),
     'schema',n.nspname,'object_type',d.defaclobjtype,'acl',d.defaclacl::text))
     from pg_default_acl d left join pg_namespace n on n.oid=d.defaclnamespace
     where n.nspname='pintheory_sync' or (d.defaclnamespace=0 and pg_get_userbyid(d.defaclrole)='postgres')),
  'history_columns', (select jsonb_agg(a.attname order by a.attnum) from pg_attribute a
     where a.attrelid=to_regclass('supabase_migrations.schema_migrations') and a.attnum>0 and not a.attisdropped)
) as report`);
const catalog = rows[0].report;
const drift = [];
const check = (ok, object, detail) => { if (!ok) drift.push({ object, detail }); };
const compact = text => text?.replace(/\s+/g, '').toLowerCase();
for (const e of expected) {
  const f = catalog.functions.find(f => f.signature === e.signature);
  check(f?.present, e.signature, 'missing function');
  if (!f?.present) continue;
  check(f.raw_equal, e.signature, 'body differs (raw comparison; inspect whitespace hashes and body)');
  const a = e.attributes;
  const attributesMatch = f.owner === 'postgres' && f.result === a.match(/^returns\s+(\w+)/i)[1]
    && f.language === a.match(/language\s+(\w+)/i)[1]
    && f.security_definer === /security definer/i.test(a) && f.strict === /\bstrict\b/i.test(a)
    && f.volatility === (/\bimmutable\b/i.test(a) ? 'i' : /\bstable\b/i.test(a) ? 's' : 'v')
    && f.parallel === 'u' && f.kind === 'f' && JSON.stringify(f.config) === '["search_path=pg_catalog"]';
  check(attributesMatch, e.signature, 'owner/return/language/security/volatility/strict/search_path/parallel/kind differs');
  // Only these known scalar casts are introduced by pg_get_function_arguments
  // for this baseline's literal defaults. No body normalization is used here.
  check(compact(f.arguments.replace(/::(?:text\[\]|text|integer|boolean|numeric|jsonb)/g, '')) === compact(e.parameters),
    e.signature, 'argument names/types/defaults differ');
  const isPublic = e.signature.startsWith('public.');
  const serviceOnly = e.signature.startsWith('public.pintheory_purge_account(');
  const grantees = ['postgres', ...(isPublic ? [serviceOnly ? 'service_role' : 'authenticated'] : [])];
  check(f.acl_entries?.length === grantees.length && f.acl_entries.every(a => grantees.includes(a.grantee)
    && a.grantor === 'postgres' && !a.grantable && a.privilege === 'EXECUTE')
    && f.effective_api_execute.anon === false
    && f.effective_api_execute.authenticated === (isPublic && !serviceOnly)
    && f.effective_api_execute.service_role === serviceOnly, e.signature, 'explicit/effective EXECUTE ACL differs');
}
for (const f of catalog.extra_functions ?? []) check(false, f.signature, 'additional function in comparison scope');
for (const [name, e] of Object.entries(tableBaseline)) {
  const table = `pintheory_sync.${name}`;
  const t = catalog.tables?.find(t => t.table === table);
  check(!!t, table, 'missing table');
  if (!t) continue;
  check(t.owner === 'postgres' && t.kind === 'r' && t.rls && !t.force_rls, table, 'owner/kind/RLS differs');
  check(t.acl === '{postgres=arwdDxtm/postgres}' || t.acl === '{postgres=arwdDxt/postgres}', table, 'table ACL differs');
  check(Object.values(t.effective_api).every(v => !v), table, 'effective API table access exists');
  check(JSON.stringify(t.columns.map(c => [c.name,c.type,c.not_null,c.default])) === JSON.stringify(e.columns)
    && t.columns.every((c,i) => c.position === i+1 && !c.identity && !c.generated && !c.acl), table, 'columns/types/nullability/defaults/column ACL differ');
  const constraints = { ...e.checks, [`${name}_pkey`]: `PRIMARY KEY (${e.primary})`,
    [`${name}_user_id_fkey`]: `FOREIGN KEY (user_id) REFERENCES ${e.foreign} ON DELETE CASCADE` };
  check(t.constraints?.length === Object.keys(constraints).length && t.constraints.every(c =>
    c.definition === constraints[c.name] && c.validated && !c.deferrable && !c.initially_deferred
    && c.type === (c.name.endsWith('_pkey') ? 'p' : c.name.endsWith('_fkey') ? 'f' : 'c')),
    table, 'constraints/validation/deferability differ');
  const indexes = { [`${name}_pkey`]: `CREATE UNIQUE INDEX ${name}_pkey ON ${table} USING btree (${e.primary})` };
  if (name === 'records') indexes.records_handicap_source_unique = "CREATE UNIQUE INDEX records_handicap_source_unique ON pintheory_sync.records USING btree (user_id, source_saved_round_id) WHERE ((kind = 'handicap_round'::text) AND (source_saved_round_id IS NOT NULL))";
  check(t.indexes?.length === Object.keys(indexes).length && t.indexes.every(i =>
    i.definition === indexes[i.name] && i.valid && i.ready && i.unique && i.primary === i.name.endsWith('_pkey')), table, 'indexes differ');
  check(t.policies?.length === 1 && t.policies.every(p => p.name === e.policy && p.command === 'r'
    && p.permissive && JSON.stringify(p.roles) === '["authenticated"]' && p.check === null
    && p.using === '(user_id = ( SELECT auth.uid() AS uid))'), table, 'policies differ');
}
check(catalog.tables?.length === 4, 'pintheory_sync', 'additional/missing tables');
const syncSchema = catalog.schemas?.find(s => s.name === 'pintheory_sync');
check(syncSchema?.owner === 'postgres' && syncSchema.acl === '{postgres=UC/postgres}'
  && Object.values(syncSchema.effective_api).every(a => !a.usage && !a.create), 'pintheory_sync', 'schema owner/ACL differs');
const expectedTriggers = [
  'CREATE TRIGGER immutable_change_events BEFORE DELETE OR UPDATE ON pintheory_sync.change_events FOR EACH ROW EXECUTE FUNCTION pintheory_sync.reject_history_change()',
  'CREATE TRIGGER immutable_mutation_receipts BEFORE DELETE OR UPDATE ON pintheory_sync.mutation_receipts FOR EACH ROW EXECUTE FUNCTION pintheory_sync.reject_history_change()',
  'CREATE TRIGGER mutation_receipts_domain_validation BEFORE INSERT ON pintheory_sync.mutation_receipts FOR EACH ROW EXECUTE FUNCTION pintheory_sync.validate_mutation_receipt()',
  'CREATE TRIGGER records_domain_validation BEFORE INSERT OR UPDATE OF kind, payload, deleted_at ON pintheory_sync.records FOR EACH ROW EXECUTE FUNCTION pintheory_sync.validate_record_payload()'
];
const syncTriggers = (catalog.triggers ?? []).filter(t => t.table.startsWith('pintheory_sync.'));
check(syncTriggers.length === 4 && syncTriggers.every(t => t.enabled === 'O' && expectedTriggers.includes(t.definition)),
  'pintheory_sync', 'custom triggers differ');
// Only the migration ledger is read outside pg_catalog, and only after presence
// and column checks. Never read stored statements (which may include fixtures).
let history = null;
if (presence.migration_history && catalog.history_columns?.includes('version')) {
  history = query('select version from supabase_migrations.schema_migrations order by version');
}
console.log(JSON.stringify({ project, generated_at: new Date().toISOString(),
  scope: 'catalog-only; first three cumulative migrations; no application/user rows or RPC calls',
  normalization_warning: 'Whitespace hashes are diagnostic only: whitespace inside literals/comments is also removed. Never certify semantic equivalence on this alone.',
  migrations, expected_functions: expected.map(({ body, ...f }) => f), presence, history,
  comparison: { drift, structurally_matches: drift.length === 0,
    caveats: ['Catalog comparison does not execute historical data preflights or runtime tests.',
      'Default ACLs and auth.users custom triggers are inventoried separately; review before reconciliation.',
      'No migration repair or migration application is performed.'] }, catalog }, null, 2));