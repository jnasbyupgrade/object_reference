\set ECHO none

\i test/load.sql

SELECT plan(
  0
  +4 -- default disable/enable round-trip disables, then restores, the trigger
  +4 -- disable/enable preserves a non-default prior state instead of assuming enabled
  +3 -- nested disable() without an intervening enable() is rejected
  +1 -- enable() without a matching disable() is rejected
  +1 -- disable() rejects an unknown event trigger name
  +2 -- schema-qualification (search_path)
);

-- Default disable/enable round-trip
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable()$$
  , 'event_trigger__disable() disables the default trigger'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'zzz__object_reference_drop')
  , 'D'
  , 'zzz__object_reference_drop is disabled while a call is in effect'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'event_trigger__enable() re-enables it'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'zzz__object_reference_drop')
  , 'O'
  , 'zzz__object_reference_drop is back to its original (origin) state'
);

-- Preserve a non-default prior state (already disabled for unrelated reasons)
SELECT lives_ok(
  $$ALTER EVENT TRIGGER zzz_object_reference_capture DISABLE$$
  , 'manually disable zzz_object_reference_capture ahead of time'
);
SELECT lives_ok(
  $$
    SELECT _object_reference.event_trigger__disable('{zzz_object_reference_capture}');
    SELECT _object_reference.event_trigger__enable();
  $$
  , 'disable()/enable() round-trip on an already-disabled trigger'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'zzz_object_reference_capture')
  , 'D'
  , 'still disabled afterward -- its prior state was preserved, not assumed enabled'
);
SELECT lives_ok(
  $$ALTER EVENT TRIGGER zzz_object_reference_capture ENABLE$$
  , 'restore zzz_object_reference_capture for later tests'
);

-- Nested disable() without an intervening enable()
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable()$$
  , 'disable() the first time'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable()$$
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
