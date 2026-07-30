# Committed-once install of the extension (see test/install/load.sql).
# pgxntool's native test/install feature runs it COMMITTED, before the suite,
# in its own pg_regress session; state persists into every (rolled-back)
# test/sql/ file. Set explicitly to `yes` (not auto-detected) so an emptied
# test/install/ becomes a hard error instead of silently turning this off.
PGXNTOOL_ENABLE_TEST_INSTALL = yes

# TEST_LOAD_SOURCE selects how test/install/load.sql installs the extension:
#   - fresh (default): CREATE EXTENSION object_reference CASCADE (current
#     version).
#   - update: CREATE EXTENSION at TEST_UPDATE_FROM (default 0.1.0 -- the only
#     released version older than current) then ALTER EXTENSION UPDATE -- to
#     TEST_UPDATE_TO if set, otherwise to the current version. Running the
#     SAME suite with the SAME expected output against the updated database
#     verifies it behaves identically to a fresh install.
#   - existing: the extension is ALREADY installed in the target database (by
#     a binary pg_upgrade, or an ALTER EXTENSION UPDATE done outside the
#     suite). load.sql does not touch it; it only asserts presence + current
#     version. Pair with CONTRIB_TESTDB=<db> and
#     EXTRA_REGRESS_OPTS=--use-existing so pg_regress runs against that
#     database instead of dropping and recreating a throwaway one.
#
# The mode (and the update from/to versions, and TEST_SCHEMA below) are
# signalled to test/install/load.sql and test/deps.sql by placeholder GUCs.
# pg_regress does not forward make variables, but the psql processes it spawns
# inherit the environment, so PGOPTIONS reaches them.
#
# The GUCs are exported UNCONDITIONALLY, so the SQL side can read them WITHOUT
# missing_ok and fail loudly if they did not propagate. Relying on an absent
# GUC to mean "fresh"/"empty" is unsafe: a silent break anywhere in the
# make -> PGOPTIONS -> env -> psql chain would quietly run the wrong mode.
#
# TEST_LOAD_SOURCE must be exactly `fresh`, `update` or `existing`; anything
# else is a hard error at parse time (so e.g. `make test TEST_LOAD_SOURCE=typo`
# fails fast rather than defaulting).
TEST_LOAD_SOURCE ?= fresh
ifeq ($(filter $(TEST_LOAD_SOURCE),fresh update existing),)
$(error TEST_LOAD_SOURCE must be 'fresh', 'update' or 'existing', got '$(TEST_LOAD_SOURCE)')
endif

# update-mode version range (read by test/install/load.sql only in update
# mode). Empty TEST_UPDATE_TO means "update to the current default_version".
# 0.1.0 is the only released version older than the current default (0.2.0),
# so it's the only floor there is to test right now -- no multiple-origin
# update-path duplicity to worry about yet (see
# sql/object_reference--0.1.0--0.2.0.sql, and PostgreSQL takes the SHORTEST
# update path, so that's the only script a plain `ALTER EXTENSION UPDATE` from
# 0.1.0 can ever take anyway).
TEST_UPDATE_FROM ?= 0.1.0
TEST_UPDATE_TO ?=

# TEST_SCHEMA: independent of TEST_LOAD_SOURCE above -- not *how* the
# extension got installed, but *where* the test session's ambient
# search_path targets while doing it. Empty (the default) means "don't target
# any schema at all" -- let the ambient search_path resolve naturally; a
# non-empty value creates and targets that schema first. See test/schema.sql.
TEST_SCHEMA ?=

export PGOPTIONS := $(PGOPTIONS) -c object_reference.test_load_mode=$(TEST_LOAD_SOURCE) -c object_reference.test_update_from=$(TEST_UPDATE_FROM) -c object_reference.test_update_to=$(TEST_UPDATE_TO) -c object_reference.test_schema=$(TEST_SCHEMA)

# Convenience wrapper: `make test-update` == `make test TEST_LOAD_SOURCE=update`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the
# parse-time TEST_LOAD_SOURCE conditional above re-evaluates with update set.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=update

# Safeguard for `make results`: refuses to copy test/results/ over
# test/expected/ while the suite shows real failures, so a stale/incorrect
# expected output can't get baked in silently. Bypass for one already-reviewed
# run with PGXNTOOL_ENABLE_VERIFY_RESULTS=no.
PGXNTOOL_ENABLE_VERIFY_RESULTS = yes

include pgxntool/base.mk

# sql/object_reference--0.1.0.sql is a frozen historical version file, not the
# current default_version -- the DATA wildcard above only picks up the CURRENT
# version file plus update-diff scripts (sql/*--*--*.sql), so a historical
# single-version file silently never gets installed unless listed explicitly
# (Postgres-Extensions/pgxntool#48). Without this, TEST_LOAD_SOURCE=update's
# `CREATE EXTENSION object_reference VERSION '0.1.0'` fails with "extension
# ... is not available".
DATA += sql/object_reference--0.1.0.sql

testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this
testdeps: test_factory

install: cat_tools

# pgxntool's check-stale-expected target (added in pgxntool 2.2.0) depends on
# installcheck but is listed before install in TEST_DEPS, and Make evaluates a
# target's prerequisites in file-parse order across stanzas -- so plain
# `make test` ran installcheck before install ever happened. Force installcheck
# to require install locally until that's fixed upstream.
installcheck: install

# test/install/load.out (and its .diff, on a mismatch) are transient run
# artifacts, not committed expected output -- see the comment at the top of
# test/install/load.sql for why pg_regress writes them where it does.
EXTRA_CLEAN += test/install/load.out test/install/load.diff

test: dump_test
extra_clean += $(wildcard test/dump/*.log)
dump_test: test/dump/run.sh test/helpers/object_table.sql $(wildcard test/dump/*.sql)
	$< -f # Force drop of databases if they exist

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	pgxn install --unstable cat_tools


.PHONY: test_factory
test_factory: $(DESTDIR)$(datadir)/extension/test_factory.control
$(DESTDIR)$(datadir)/extension/test_factory.control:
	pgxn install test_factory
