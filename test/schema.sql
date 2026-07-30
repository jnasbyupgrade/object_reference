/*
 * TEST_SCHEMA (see Makefile): single source of truth for reading the
 * schema-matrix GUC, \i'd by both test/install/load.sql (once, before
 * installing the extension) and test/deps.sql (every per-test session).
 * It has to be re-read per test session, not just once at install time,
 * because search_path is session-local -- it does not carry over from the
 * committed install session into each test/sql session's own connection.
 *
 * This file only reads the GUC and computes whether it's set; each \i site
 * decides what to actually do with object_reference_test_schema (the
 * object_reference extension's own schema is fixed via object_reference.control
 * and unaffected by search_path, so this is about where the *test session's*
 * ambient search_path points -- e.g. for CREATE EXTENSION to prove it doesn't
 * secretly depend on schema ordering, or for a test's own unqualified scratch
 * objects to land somewhere other than the default).
 *
 * Read WITHOUT missing_ok and exported unconditionally by the Makefile, same
 * as object_reference.test_load_mode: relying on an absent GUC to mean "empty"
 * would let a silent break anywhere in the make -> PGOPTIONS -> env -> psql
 * chain go unnoticed.
 */
SELECT current_setting('object_reference.test_schema') AS object_reference_test_schema
\gset

SELECT :'object_reference_test_schema' <> '' AS object_reference_has_test_schema
\gset
