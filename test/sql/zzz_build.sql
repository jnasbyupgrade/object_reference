\set ECHO none

-- The \'s confuse grep for some reason... :/
\! cat sql/object_reference.sql | grep -v 'echo It will FAIL during pg_dump! ' > test/temp_load.not_sql # TODO: move this to Make after removing clean from testdeps

-- Loads deps, but not extension itself
\i test/pgxntool/setup.sql

-- Need to do this now (rather than just before temp_load.not_sql, as
-- before) so that the "cat_tools already exists" NOTICE below -- a new
-- side effect of test/install/load.sql now installing cat_tools once,
-- persistently, ahead of every test -- is also stable across versions (no
-- line #s from ereport messages; see the comment further down for the
-- original rationale, which applies here for the same reason).
\set VERBOSITY default

CREATE EXTENSION IF NOT EXISTS cat_tools;

/*
 * test/install/load.sql installs object_reference once, committed, before
 * this (and every other) test runs -- but this test intentionally bypasses
 * CREATE EXTENSION to sanity-check the raw, unwrapped source file (see the
 * \echo warnings at its own top: it is NOT meant to be loaded this way).
 * Drop the committed install first so CREATE SCHEMA object_reference below
 * doesn't collide with the schema the extension already owns; this DROP
 * lives inside this test's own transaction, which is never committed (see
 * "TRANSACTION INTENTIONALLY LEFT OPEN" below), so it doesn't affect the
 * persistent install other test files still rely on. DROP EXTENSION does
 * NOT drop the schema it auto-created (PostgreSQL never implicitly drops a
 * schema named in a .control file's "schema" setting, even one it created
 * itself), so the schema -- now empty -- needs dropping too before
 * recreating it below.
 */
DROP EXTENSION IF EXISTS object_reference CASCADE;
DROP SCHEMA IF EXISTS object_reference;

CREATE SCHEMA object_reference;

-- doesn't work :/ SET client_min_messages = FATAL; -- Need to surpress WARNING or turn down verbosity. Suppressing WARNING seems the better idea...
-- (VERBOSITY already set to default above)
\i test/temp_load.not_sql

\echo Loaded OK!
\echo # TRANSACTION INTENTIONALLY LEFT OPEN!

-- vi: expandtab sw=2 ts=2
