\set ECHO none

\i test/load.sql

/*
 * event_trigger__disable()/__enable() are ALTER EVENT TRIGGER under the
 * hood, which is a database-wide change visible to every session the
 * instant it runs (unlike the session-local session_replication_role trick
 * it replaces) -- so this test exercises the mechanism against its OWN
 * dummy event triggers, never the real zzz_* ones other test files in this
 * same parallel run depend on staying enabled.
 */
CREATE FUNCTION event_trigger_disable_test__noop() RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
END
$$;
CREATE EVENT TRIGGER event_trigger_disable_test__a ON ddl_command_start EXECUTE FUNCTION event_trigger_disable_test__noop();
CREATE EVENT TRIGGER event_trigger_disable_test__b ON ddl_command_start EXECUTE FUNCTION event_trigger_disable_test__noop();

SELECT plan(
  0
  +1 -- default target is zzz__object_reference_drop
  +7 -- multi-trigger disable/enable preserves each one's own prior state
  +3 -- nested disable() without an intervening enable() is rejected
  +1 -- enable() without a matching disable() is rejected
  +1 -- disable() rejects an unknown event trigger name
  +2 -- schema-qualification (search_path)
);

-- Default target (checked via source, never invoked against a real trigger)
SELECT matches(
  pg_catalog.pg_get_functiondef('_object_reference.event_trigger__disable(name[])'::regprocedure)
  , 'zzz__object_reference_drop'
  , 'default event trigger to disable is zzz__object_reference_drop'
);

-- Multi-trigger disable/enable, preserving each trigger's own prior state
SELECT lives_ok(
  $$ALTER EVENT TRIGGER event_trigger_disable_test__b DISABLE$$
  , 'manually disable test trigger b ahead of time'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,event_trigger_disable_test__b}')$$
  , 'disable() both test triggers'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__a')
  , 'D'
  , 'test trigger a is disabled while a call is in effect'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__b')
  , 'D'
  , 'test trigger b is (still) disabled while a call is in effect'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() restores both'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__a')
  , 'O'
  , 'test trigger a is back to its original (origin) state'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__b')
  , 'D'
  , 'test trigger b is still disabled -- its prior state was preserved, not assumed enabled'
);

-- Nested disable() without an intervening enable()
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , 'disable() the first time'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , NULL
  , 'event_trigger__disable() called while a previous call is still in effect'
  , 'a second disable() without enable() in between is rejected'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() cleans up so later tests are unaffected'
);

-- enable() without a matching disable()
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , NULL
  , 'event_trigger__enable() called without a matching event_trigger__disable()'
  , 'enable() without disable() is rejected'
);

-- Unknown event trigger name
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{no_such_event_trigger}')$$
  , NULL
  , 'event trigger "no_such_event_trigger" does not exist'
  , 'disable() rejects an unknown event trigger name'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
