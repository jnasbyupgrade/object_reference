/*
 * ON_ERROR_STOP matters here more than in a normal test/sql/ file: pg_regress
 * resolves this schedule entry's expected-output path via "../install/load"
 * relative to both --inputdir/expected and --outputdir/results, which
 * collapse to the SAME file (test/install/load.out) -- so content diffing
 * against it is a no-op self-comparison that can never fail. Without
 * ON_ERROR_STOP, an error here (e.g. the existing-mode assert below, or a
 * broken update script) would print an ERROR and then just keep going,
 * leaving pg_regress with nothing to detect it by. ON_ERROR_STOP makes psql
 * itself exit non-zero instead, which pg_regress DOES check independent of
 * any output diff.
 */
\i test/pgxntool/psql.sql

/*
 * Single, committed-once installer for the test suite's dependency: the
 * object_reference extension itself (see the modes below).
 *
 * pgxntool's test/install feature runs this file COMMITTED, in its own
 * pg_regress session, BEFORE the main pgTAP suite. Because its state is
 * committed it persists into every test and runs ONCE instead of per-test
 * (pgTAP rolls back each test/sql/ file, so tests read these objects but
 * never modify them). test/load.sql (\i'd per test) no longer installs the
 * extension itself -- only this file does.
 *
 * Three modes, selected by the object_reference.test_load_mode placeholder
 * GUC, which the Makefile TEST_LOAD_SOURCE block sets via PGOPTIONS (fresh is
 * the default):
 *   - fresh (default): CREATE EXTENSION object_reference CASCADE (current
 *     version). CASCADE is required because object_reference requires
 *     cat_tools and count_nulls, neither of which is installed yet here.
 *   - update: CREATE EXTENSION at an older version
 *     (object_reference.test_update_from, default 0.1.0 -- the only released
 *     version older than current) then ALTER EXTENSION UPDATE -- to
 *     object_reference.test_update_to when that GUC is non-empty, otherwise
 *     to the current default_version. Reusing the SAME suite and expected
 *     output asserts an updated database behaves identically to a fresh
 *     install.
 *   - existing: the extension is ALREADY installed (by binary pg_upgrade, or
 *     an ALTER EXTENSION UPDATE performed outside the suite). load.sql must
 *     NOT drop/create/update it -- that would destroy exactly what the suite
 *     validates. It only asserts presence + current version.
 *
 * object_reference's own role-creation (object_reference__usage,
 * object_reference__dependency) already tolerates being re-run -- both
 * versions wrap CREATE ROLE in a DO block that swallows duplicate_object --
 * so unlike some other extensions in this family, no separate role-drop step
 * is needed here before a fresh/update re-install; ordinary
 * DROP EXTENSION ... CASCADE plus the extension script's own idempotent role
 * creation is sufficient.
 */
SET client_min_messages = WARNING;

/*
 * TEST_SCHEMA (see test/schema.sql): independent of load mode -- targets the
 * session's ambient search_path before the extension is (re)installed below,
 * so a fresh/update install can be proven not to secretly depend on schema
 * ordering. Applied uniformly across all three modes; in existing mode it
 * only affects this session's own search_path, since the extension itself is
 * untouched.
 */
\i test/schema.sql
\if :object_reference_has_test_schema
CREATE SCHEMA IF NOT EXISTS :"object_reference_test_schema";
SET search_path = :"object_reference_test_schema";
\endif

/*
 * Mode selection. The Makefile always exports object_reference.test_load_mode
 * via PGOPTIONS. Read it WITHOUT missing_ok: if the GUC did not propagate (a
 * break anywhere in make -> PGOPTIONS -> env -> psql), current_setting errors
 * here and the whole install step fails loudly, instead of silently falling
 * back to a default and running the wrong suite. The DO block then rejects
 * any value other than fresh/update/existing with a clear message.
 */
SELECT current_setting('object_reference.test_load_mode') AS object_reference_test_load_mode
\gset

DO $DO$
BEGIN
  IF current_setting('object_reference.test_load_mode') NOT IN ('fresh', 'update', 'existing') THEN
    RAISE EXCEPTION
      'object_reference.test_load_mode must be ''fresh'', ''update'' or ''existing'', got ''%'''
      , current_setting('object_reference.test_load_mode')
    ;
  END IF;
END
$DO$;

SELECT
    :'object_reference_test_load_mode' = 'update'   AS object_reference_mode_update
  , :'object_reference_test_load_mode' = 'existing' AS object_reference_mode_existing
\gset

\if :object_reference_mode_existing
/*
 * existing mode: do NOT touch the extension. Assert it is installed and at
 * the current default_version -- the pg_upgrade / external update the
 * database just went through is exactly what the suite is validating, so
 * dropping or reinstalling it would defeat the test. Fail loudly on absence
 * or mismatch.
 */
DO $DO$
DECLARE
  v_installed text := (SELECT extversion FROM pg_extension WHERE extname = 'object_reference');
  v_default   text := (SELECT default_version FROM pg_available_extensions WHERE name = 'object_reference');
BEGIN
  IF v_installed IS NULL THEN
    RAISE EXCEPTION 'test_load_mode=existing but the object_reference extension is not installed';
  END IF;
  IF v_installed IS DISTINCT FROM v_default THEN
    RAISE EXCEPTION
      'object_reference is installed at version % but the current default_version is %'
      , v_installed, v_default
    ;
  END IF;
END
$DO$;
\else
/*
 * fresh / update: (re)install from scratch. Drop-first so a re-run on a
 * persistent cluster installs the newest build instead of reusing stale
 * objects. CASCADE both drops and (re)creates cat_tools/count_nulls along
 * with object_reference; that's fine here -- they're separate extensions
 * with their own independent lifecycle, and object_reference's test suite
 * only ever needs whatever their own current default_version provides.
 */
DROP EXTENSION IF EXISTS object_reference CASCADE;

\if :object_reference_mode_update
/*
 * update mode: install an older version, then ALTER EXTENSION UPDATE. The
 * from/to versions come from the Makefile (TEST_UPDATE_FROM / TEST_UPDATE_TO,
 * exported as GUCs). An empty test_update_to means "update to the current
 * default_version" (the widest path); a non-empty value targets a specific
 * version.
 */
SELECT current_setting('object_reference.test_update_from') AS object_reference_test_update_from \gset
SELECT current_setting('object_reference.test_update_to')   AS object_reference_test_update_to   \gset
/*
 * Build the optional target clause once so a SINGLE ALTER EXTENSION covers
 * both cases: an empty test_update_to yields '' (update to the current
 * default_version -- the widest path); a non-empty value yields "TO '<v>'".
 * format(%L) quotes the version literal safely; the bare :clause
 * interpolation below then drops it in verbatim.
 */
SELECT CASE WHEN :'object_reference_test_update_to' = '' THEN ''
            ELSE format('TO %L', :'object_reference_test_update_to') END
  AS object_reference_update_to_clause \gset

CREATE EXTENSION object_reference VERSION :'object_reference_test_update_from' CASCADE;
/*
 * Suppress the deprecation NOTICEs an update script may emit.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION object_reference UPDATE :object_reference_update_to_clause;
SET client_min_messages = WARNING;
\else
CREATE EXTENSION object_reference CASCADE;
\endif
-- end \if :object_reference_mode_update (fresh vs. update install branch)
\endif
-- end \if :object_reference_mode_existing (existing mode skips the whole (re)install block)

-- vi: expandtab ts=2 sw=2
