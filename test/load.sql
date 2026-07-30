/*
 * Per-test setup, \i'd from every test/sql file inside its own rolled-back
 * transaction (see test/pgxntool/setup.sql). The object_reference
 * extension itself is no longer (re)installed here -- test/install/load.sql
 * installs it ONCE, committed, before any test/sql/ file runs (see that file
 * for the fresh/update/existing modes); state from that install persists
 * into every test. This file's \i chain (test/pgxntool/setup.sql ->
 * test/deps.sql) still handles per-test, session-local setup (pgTAP,
 * search_path -- see test/deps.sql for the TEST_SCHEMA handling).
 */
\i test/pgxntool/setup.sql

/*
 * Squelch NOTICEs for the rest of this test. Previously set right before the
 * per-test CREATE EXTENSION (to quiet its dependency-install chatter) and
 * left in place afterward, so every later statement in the same test file
 * ran quiet too; test/install/load.sql now owns the CREATE EXTENSION step,
 * but test output still expects the same lowered level for everything after
 * this point.
 */
SET client_min_messages = WARNING;
