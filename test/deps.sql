-- Note: pgTap is loaded by setup.sql

/*
 * TEST_SCHEMA (see test/schema.sql and test/install/load.sql): re-applied
 * here per test session, since search_path is session-local and does not
 * carry over from test/install/load.sql's own (committed, separate) session.
 * tap must stay reachable for pgTAP's own unqualified functions
 * (plan(), finish(), ...), so it's appended rather than replacing
 * tap_setup.sql's search_path outright. Empty test_schema leaves search_path
 * exactly as tap_setup.sql already set it (tap, public) -- no CREATE SCHEMA,
 * no SET search_path -- so the empty leg still proves nothing is hardcoded to
 * a particular target schema.
 */
\i test/schema.sql
\if :object_reference_has_test_schema
CREATE SCHEMA IF NOT EXISTS :"object_reference_test_schema";
SET search_path = :"object_reference_test_schema", tap, public;
\endif

/*
 * Normally these should be loaded by the cascade!
CREATE EXTENSION IF NOT EXISTS cat_tools;
 */
