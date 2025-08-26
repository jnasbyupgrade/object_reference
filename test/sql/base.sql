\set ECHO none

\i test/load.sql

CREATE TABLE test_table();

SELECT plan(
  0
  +1 -- schema
  +3 -- initial
  +2 -- errors
  +1 -- create extensions
);

-- Schema
SELECT schema_privs_are(
  '_object_reference'
  , 'object_reference__dependency'
  , array[ 'USAGE' ]
);

SELECT table_privs_are(
  '_object_reference', 'object'
  , 'object_reference__dependency'
  , '{REFERENCES}'::text[]
);

-- Initial
SELECT lives_ok(
  $$CREATE TEMP TABLE test_object AS SELECT object_reference.object__getsert('table', 'test_table') AS object_id;$$
  , $$CREATE TEMP TABLE test_object AS SELECT object_reference.object__getsert('table', 'test_table') AS object_id;$$
);
SELECT is(
  (SELECT object_oid FROM _object_reference._object_v WHERE object_id = (SELECT object_id FROM test_object))
  , 'test_table'::regclass::oid
  , 'Verify object_oid field is correct'
);
SELECT is(
  object_reference.object__getsert('table', 'test_table')
  , (SELECT object_id FROM test_object)
  , 'Existing object works, provides correct ID'
);

-- errors
SELECT throws_ok(
  $$SELECT object_reference.object__getsert('table', 'test_table', secondary:='test')$$
  , NULL
  , 'secondary may not be specified for table objects'
  , 'secondary may not be specified for table objects'
);

-- Create extensions
SELECT lives_ok(
  $$CREATE EXTENSION test_factory$$
  , $$CREATE EXTENSION test_factory$$
);
  
\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2
