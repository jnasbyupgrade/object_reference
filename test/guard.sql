/*
 * Dependency guard for "existing" mode (TEST_LOAD_SOURCE=existing): plants an
 * object that hard-depends on a stable, foundational object_reference member,
 * so an accidental non-CASCADE `DROP EXTENSION object_reference` fails
 * instead of silently succeeding and letting a subsequent fresh reinstall
 * quietly pass "existing"-mode CI against a database that was never actually
 * carried through pg_upgrade/update.
 *
 * NOT wired into `make test` -- this file is intentionally outside
 * test/install/ (whose *.sql files pgxntool auto-schedules into every
 * `make test` run) so it doesn't affect fresh/update-mode runs, which have no
 * need for it. It's meant to be invoked directly with psql, as one step of a
 * future existing-mode CI flow (plant it right after installing/upgrading,
 * assert the guarded DROP fails, re-assert after every subsequent step -- see
 * the doc comment above the anchor below for why this table was chosen).
 *
 * Usage: psql -f test/guard.sql <target database>
 *
 * To prove it: after running this file,
 *   DROP EXTENSION object_reference;             -- must fail
 *   DROP EXTENSION object_reference CASCADE;     -- succeeds, and takes
 *                                                    object_reference_drop_guard.guard with it
 */
CREATE SCHEMA IF NOT EXISTS object_reference_drop_guard;

/*
 * Anchor: _object_reference.object.object_id. This table is the extension's
 * own identity registry -- every other table (_object_oid, object_group__object,
 * ...) exists to attach more information to a row already present here, so an
 * update path that dropped or renamed it would no longer be recognizable as
 * this extension at all. object_id specifically (rather than the whole
 * table, or one of its other columns) is the narrowest possible anchor: it's
 * the surrogate key every foreign reference into this table already depends
 * on, so it's guaranteed stable for as long as the extension's core identity
 * model exists in any recognizable form.
 */
CREATE OR REPLACE VIEW object_reference_drop_guard.guard AS
  SELECT object_id FROM _object_reference.object WHERE false;
