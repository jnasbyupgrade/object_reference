\set ECHO none

\i test/load.sql

SELECT plan(
  0
  +2 -- begin()/end() basic round trip
  +3 -- nested begin() without an intervening end() is rejected
  +1 -- end() without a matching begin() is rejected
  +5 -- zzz_object_reference_capture self-recognizes and stands down while begin() is in effect
  +4 -- zzz__object_reference_drop self-recognizes and stands down while begin() is in effect
  +2 -- schema-qualification (search_path)
);

-- Basic round trip
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__begin()$$
  , 'begin()'
);
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__end()$$
  , 'end()'
);

-- Nested begin() without an intervening end()
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__begin()$$
  , 'begin() the first time'
);
SELECT throws_ok(
  $$SELECT _object_reference.internal_operation__begin()$$
  , NULL
  , 'internal_operation__begin() called while a previous call is still in effect'
  , 'a second begin() without end() in between is rejected'
);
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__end()$$
  , 'end() cleans up so later tests are unaffected'
);

-- end() without a matching begin()
SELECT throws_ok(
  $$SELECT _object_reference.internal_operation__end()$$
  , NULL
  , 'internal_operation__end() called without a matching internal_operation__begin()'
  , 'end() without begin() is rejected'
);

/*
 * zzz_object_reference_capture checks for an internal_operation__begin()
 * call currently in effect for THIS session and stands down -- verify
 * directly observable behavior, not the implementation.
 */
SELECT lives_ok(
  $$SELECT object_reference.capture__start(object_reference.object_group__create('internal_operation_test_group'))$$
  , 'start a capture group'
);
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__begin()$$
  , 'begin() signals self-recognizing triggers to stand down'
);
CREATE TABLE internal_operation_test_table();
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__end()$$
  , 'end() ends that window'
);
SELECT is_empty(
  $$
    SELECT 1
      FROM _object_reference.object_group__object
      WHERE object_group_id = (object_reference.object_group__get('internal_operation_test_group')).object_group_id
  $$
  , 'the table created while begin() was in effect was NOT captured'
);
SELECT lives_ok(
  $$SELECT object_reference.capture__stop('internal_operation_test_group')$$
  , 'stop the capture group'
);

/*
 * zzz__object_reference_drop checks the same signal and stands down too --
 * a tracked object dropped while begin() is in effect should NOT get
 * cleaned up (the whole point: this extension's own update scripts drop
 * and recreate their own internals without that being mistaken for a real
 * user object going away).
 */
CREATE TABLE internal_operation_drop_test_table();
SELECT lives_ok(
  $$CREATE TEMP TABLE internal_operation_drop_test AS SELECT object_reference.object__getsert('table', 'internal_operation_drop_test_table') AS object_id$$
  , 'track a test table'
);
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__begin()$$
  , 'begin()'
);
DROP TABLE internal_operation_drop_test_table;
SELECT lives_ok(
  $$SELECT _object_reference.internal_operation__end()$$
  , 'end()'
);
SELECT is(
  (SELECT count(*) FROM _object_reference.object WHERE object_id = (SELECT object_id FROM internal_operation_drop_test))
  , 1::bigint
  , 'the dropped table is STILL tracked -- zzz__object_reference_drop stood down while begin() was in effect'
);
/*
 * Clean up the now-stale row directly (a plain DML delete, not DDL, so it
 * fires no event trigger) rather than leaving it for _etg_fix_identity's
 * later, unrelated blanket scan to trip over: in real usage this can't
 * happen (an update script's own internal_operation window only ever
 * touches objects _is_own_object() already excludes from tracking), so
 * this is a test-only artifact of tracking an arbitrary table above.
 */
DELETE FROM _object_reference.object WHERE object_id = (SELECT object_id FROM internal_operation_drop_test);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
