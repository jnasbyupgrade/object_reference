/*
 * 0.1.0 -> 0.2.0
 *
 * Two independent changes, bundled into one release:
 *
 *  1. Stop storing reg* pseudotypes (regclass, regconfig, regdictionary,
 *     regnamespace, regoperator, regprocedure, regtype) in
 *     _object_reference._object_oid. A single plain `object_oid oid` column
 *     (already present, previously optional) now always holds the oid,
 *     regardless of object type; classid changes from regclass to oid to
 *     match. The old per-reg-type CHECK constraints and partial unique
 *     indexes existed only to keep "exactly one reg column is set" true;
 *     with one column instead of eight, that invariant is enforced simply by
 *     making object_oid NOT NULL. The null_count trigger enforced the same
 *     "exactly one set" invariant across the reg columns, so it goes with
 *     them.
 *  2. Add automatic object cleanup on group membership removal:
 *     object_reference.object__cleanup() (and the trigger that fires it) lets
 *     the tracking table release rows for objects no longer referenced by any
 *     group, once nothing else references them either.
 *
 * _object_reference._object_v and _object_v__for_update select every
 * _object_oid column, so PostgreSQL refuses to drop any of them out from
 * under the views, and CREATE OR REPLACE VIEW cannot remove columns either --
 * both views must be dropped and recreated around the column changes below.
 * Neither view is referenced by any other view, and nothing is granted on
 * them directly (privileges here come from the containing _object_reference
 * schema), so no grants need restoring afterward -- but two functions
 * (_object_reference._object_oid__add and the getsert core function, both
 * confusingly also named _object_reference._object_v__for_update) declare
 * RETURNS _object_reference._object_v, so dropping that view needs CASCADE.
 * Both functions are recreated further down (their bodies changed too), so
 * losing them here is fine.
 */

/*
 * zzz__object_reference_drop fires _etg_drop() on every sql_drop event in
 * this session (including the ones this update script itself is about to
 * make), and _etg_drop() queries _object_reference._object_v to find
 * tracked objects to clean up after whatever was just dropped. That view is
 * exactly what the DROP VIEW below removes, so the trigger would fail
 * looking up a view that, at that instant, no longer exists. Disable it for
 * the duration of this script and re-enable it at the end, once the view
 * (and everything else _etg_drop depends on) is back.
 */
ALTER EVENT TRIGGER zzz__object_reference_drop DISABLE;

DROP VIEW _object_reference._object_v__for_update;
DROP VIEW _object_reference._object_v CASCADE;

/*
 * The old objid_must_match CHECK constraint already guarantees, for every
 * existing row, that objid equals whichever single reg-type (or plain object_oid) column
 * was actually populated for that object type -- so backfilling object_oid
 * FROM objid is exact (and far simpler than re-deriving it from whichever
 * reg* column happens to be set), and is exactly what the new
 * objid_must_match constraint below requires regardless of which reg type
 * (if any) a given row originally used.
 */
UPDATE _object_reference._object_oid SET object_oid = objid WHERE object_oid IS NULL;

ALTER TABLE _object_reference._object_oid
  DROP COLUMN regclass
  , DROP COLUMN regconfig
  , DROP COLUMN regdictionary
  , DROP COLUMN regnamespace
  , DROP COLUMN regoperator
  , DROP COLUMN regprocedure
  , DROP COLUMN regtype
  , ALTER COLUMN classid TYPE oid USING classid::oid
  , ALTER COLUMN object_oid SET NOT NULL
;

/*
 * Dropping the reg* columns took the old objid_must_match CHECK (its
 * coalesce(...) expression referenced them) and the per-reg-type partial
 * unique indexes with it. Recreate the constraint in its simplified form,
 * and drop the now-pointless null_count trigger: with object_oid NOT NULL,
 * "exactly one of the optional reference columns is set" is no longer a
 * meaningful invariant to enforce.
 */
ALTER TABLE _object_reference._object_oid
  ADD CONSTRAINT objid_must_match CHECK ( objid IS NOT DISTINCT FROM object_oid )
;
DROP TRIGGER null_count ON _object_reference._object_oid;

CREATE VIEW _object_reference._object_v AS
  SELECT 
      o.object_id
      , o.object_type
      , o.object_names
      , o.object_args
      , i.classid
      , i.objid
      , i.objsubid
      , i.object_oid
      , s.*
    FROM _object_reference.object o
      LEFT JOIN _object_reference._object_oid i USING(object_id)
      , _object_reference._sanity(o, i) s
;
CREATE VIEW _object_reference._object_v__for_update AS
  SELECT 
      o.object_id
      , o.object_type
      , o.object_names
      , o.object_args
      , i.classid
      , i.objid
      , i.objsubid
      , i.object_oid
      , s.*
    FROM _object_reference.object o
      LEFT JOIN _object_reference._object_oid i USING(object_id)
      , _object_reference._sanity(o, i) s
    FOR UPDATE OF o
;

/*
 * The remaining changes touch function bodies (and add new functions), all
 * created via the __object_reference.create_function() helper so they get
 * the same REVOKE-from-PUBLIC / GRANT / COMMENT treatment a fresh install
 * gives them, instead of drifting from it. The helper (and the two smaller
 * functions it depends on) is normally created and dropped within a single
 * install script's own run (see the "temporary" schema note below); an
 * update script has to bring it back to reuse it, then drop it again
 * afterward, same as a fresh install does.
 */
CREATE SCHEMA __object_reference;

CREATE FUNCTION __object_reference.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  RAISE DEBUG 'sql = %', sql;
  EXECUTE sql;
END
$body$;

CREATE FUNCTION __object_reference.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  c_clean_args text := cat_tools.routine__parse_arg_types_text(args);

  create_template CONSTANT text := $template$
CREATE OR REPLACE FUNCTION %s(
%s
) RETURNS %s AS
%L
$template$
  ;

  revoke_template CONSTANT text := $template$
REVOKE ALL ON FUNCTION %s(
%s
) FROM public;
$template$
  ;

  grant_template CONSTANT text := $template$
GRANT EXECUTE ON FUNCTION %s(
%s
) TO %s;
$template$
  ;

  comment_template CONSTANT text := $template$
COMMENT ON FUNCTION %s(
%s
) IS %L;
$template$
  ;

BEGIN
  PERFORM __object_reference.exec( format(
      create_template
      , function_name
      , args
      , options -- TODO: Force search_path if options ~* 'definer'
      , body
    ) )
  ;
  PERFORM __object_reference.exec( format(
      revoke_template
      , function_name
      , c_clean_args
    ) )
  ;

  IF grants IS NOT NULL THEN
    PERFORM __object_reference.exec( format(
        grant_template
        , function_name
        , c_clean_args
        , grants
      ) )
    ;
  END IF;

  IF comment IS NOT NULL THEN
    PERFORM __object_reference.exec( format(
        comment_template
        , function_name
        , c_clean_args
        , comment
      ) )
    ;
  END IF;
END
$body$;

SELECT __object_reference.create_function(
  '_object_reference._object_oid__add'
  , $args$
  object_id _object_reference._object_oid.object_id%TYPE
  , object_type _object_reference.object.object_type%TYPE DEFAULT NULL
  , classid _object_reference._object_oid.classid%TYPE DEFAULT NULL
  , objid _object_reference._object_oid.objid%TYPE DEFAULT NULL
  , objsubid _object_reference._object_oid.objsubid%TYPE DEFAULT NULL
$args$
  , '_object_reference._object_v LANGUAGE plpgsql'
  , $body$
DECLARE
  r_object_v _object_reference._object_v;
BEGIN
  IF object_type IS NULL THEN
    -- Should definitely exist
    SELECT INTO STRICT object_type, classid, objid, objsubid
        o.object_type, a.classid, a.objid, a.objsubid
      FROM _object_reference.object o
        , pg_catalog.pg_get_object_address(o.object_type::text, o.object_names, o.object_args) a
      WHERE o.object_id = _object_oid__add.object_id
    ;
  END IF;
  BEGIN
    INSERT INTO _object_reference._object_oid(object_id, classid, objid, objsubid, object_oid)
      VALUES (object_id, classid, objid, objsubid, objid);

    SELECT INTO STRICT r_object_v -- Record better exist!
        *
      FROM _object_reference._object_v__for_update o
      WHERE o.object_id = _object_oid__add.object_id
    ;
  END;

  IF NOT r_object_v.ids_ok THEN
    RAISE 'id mismatch for object_id %', object_id
      USING
        DETAIL = '_object_reference._object_v = ' || pg_catalog.row_to_json(r_object_v)
        , HINT = 'this should not be possible'
    ;
  END IF;

  RETURN r_object_v;
END
$body$
  , 'Check the sanity of object and _object_oid'
);

SELECT __object_reference.create_function(
  'object_reference.unsupported'
  , ''
  , 'cat_tools.object_type[] LANGUAGE sql IMMUTABLE'
  , $body$
SELECT cat_tools.objects__shared()
  || cat_tools.objects__address_unsupported()
  || '{event trigger, partitioned table, partitioned index}'
$body$
  , 'Returns array of object types that are not supported.'
  , 'object_reference__usage'
);

SELECT __object_reference.create_function(
  '_object_reference._object_v__for_update'
  , $args$
  object_type _object_reference.object.object_type%TYPE
  , objid _object_reference._object_oid.objid%TYPE
  , objsubid _object_reference._object_oid.objsubid%TYPE
  , object_group_id int DEFAULT NULL
  , class_id regclass DEFAULT NULL
$args$
  , '_object_reference._object_v LANGUAGE plpgsql'
  , $body$
DECLARE
  c_classid CONSTANT regclass := cat_tools.object__address_classid(object_type);

  r_object_v _object_reference._object_v;
  r_address record;
  r_identity record;

  did_insert boolean := false;

  i smallint;
  sql text;
BEGIN
  ASSERT class_id IS NULL OR class_id = c_classid, format(
    'cat_tools.object__address_classid(object_type) %L <> class_id %L'
    , c_classid
    , class_id
  );
  IF object_reference.unsupported(object_type) THEN
    RAISE 'object_type % is not supported', object_type;
  END IF;

  SELECT INTO r_address * FROM pg_catalog.pg_identify_object_as_address(c_classid, objid, objsubid);

  IF r_address IS NULL THEN
    RAISE 'unable to find object'
      USING DETAIL = format(
        'pg_identify_object_as_address(%s, %s, %s) returned NULL'
        , c_classid
        , objid
        , objsubid
      )
    ;
  END IF;

  -- Refuse to track objects in temporary schemas
  SELECT INTO r_identity * FROM pg_catalog.pg_identify_object(c_classid, objid, objsubid);
  IF r_identity.schema IS NOT NULL AND (r_identity.schema LIKE 'pg_temp%' OR r_identity.schema LIKE 'pg_toast_temp%') THEN
    RAISE 'cannot track temporary object'
      USING DETAIL = format('object %s is in temporary schema %s', r_identity.identity, r_identity.schema)
      , ERRCODE = 'feature_not_supported'
    ;
  END IF;

  -- Ensure the object record exists
  SELECT INTO r_object_v
      *
    FROM _object_reference._object_v__for_update o
    WHERE (o.object_type, o.object_names, o.object_args) = (_object_v__for_update.object_type, r_address.object_names, r_address.object_args)
  ;
  IF NOT FOUND THEN
    FOR i IN 1..10 LOOP
      did_insert := true;
      INSERT INTO _object_reference.object(object_type, object_names, object_args)
        VALUES(_object_v__for_update.object_type, r_address.object_names, r_address.object_args)
        ON CONFLICT ON CONSTRAINT object__u_object_names__object_args DO NOTHING
      ;
      -- Still a small race condition here...
      SELECT INTO r_object_v
          *
        FROM _object_reference._object_v__for_update o
        WHERE (o.object_type, o.object_names, o.object_args) = (_object_v__for_update.object_type, r_address.object_names, r_address.object_args)
      ;
      EXIT WHEN FOUND;
    END LOOP;
    IF NOT FOUND THEN
      RAISE 'fell out of loop!' USING HINT = 'This should never happen.';
    END IF;
  END IF;

  ASSERT r_object_v.names_ok, 'names do not match (should not be possible)' ;

  IF object_group_id IS NOT NULL THEN
    PERFORM object_reference.object_group__object__add(object_group_id, r_object_v.object_id);
  END IF;

  -- Handle _object_oid table
  CASE
    WHEN r_object_v.ids_ok THEN
      RETURN r_object_v;

    WHEN NOT r_object_v.ids_exist THEN
      /*
       * Just need to create IDs record.
       */

      /* 
       * This shouldn't normally happen, but could occur if a restore didn't
       * finish cleanly. We know it's safe to do this because names_ok is true.
       */
      IF NOT did_insert THEN
        RAISE WARNING 'missing record in _object_reference._object_oid for object_id %', r_object_v.object_id
          USING HINT = 'This indicates a restore did not finish cleanly.'
        ;
      END IF;
      r_object_v := _object_reference._object_oid__add(r_object_v.object_id, object_type, c_classid, objid, objsubid);

    WHEN r_object_v.ids_exist THEN
      RAISE 'ids are out of sync for object_id %', r_object_v.object_id
        USING DETAIL = format(
          E'_object_reference._object_v = %L,\n    arguments (%L, %s, %s, %s)'
          , pg_catalog.row_to_json(r_object_v, true)
          , object_type
          , objid
          , objsubid
          , object_group_id
        )
        , HINT = 'this shoud not happen if event trigger "zzz_object_reference_end" is working'
      ;
    ELSE
      RAISE 'unknown condition';
  END CASE;

  RETURN r_object_v;
END
$body$
  , 'Return details of a object record, creating a new record if one does not exist.'
);

/*
 * OBJECT INFO FUNCTIONS (new in 0.2.0)
 */
SELECT __object_reference.create_function(
  'object_reference.object__describe'
  , $args$
  object_id int
$args$
  , 'text LANGUAGE sql'
  , $body$
SELECT pg_catalog.pg_describe_object(
  o.classid,
  o.objid, 
  o.objsubid
)
FROM _object_reference._object_oid o
WHERE o.object_id = $1
$body$
  , 'Return a human-readable description of the object, matching pg_describe_object() format.'
  , 'object_reference__usage'
);

SELECT __object_reference.create_function(
  'object_reference.object__identity'
  , $args$
  object_id int
  , OUT type text
  , OUT schema text
  , OUT name text
  , OUT identity text
$args$
  , 'record LANGUAGE sql'
  , $body$
SELECT 
  i.type::text,
  i.schema::text,
  i.name::text,
  i.identity::text
FROM _object_reference._object_oid o,
     LATERAL pg_catalog.pg_identify_object(o.classid, o.objid, o.objsubid) i
WHERE o.object_id = $1
$body$
  , 'Return object identification information matching pg_identify_object() format.'
  , 'object_reference__usage'
);

SELECT __object_reference.create_function(
  'object_reference.object__cleanup'
  , $args$
  object_id int
$args$
  , 'void LANGUAGE plpgsql'
  , $body$
BEGIN
  DELETE FROM _object_reference.object WHERE object.object_id = object__cleanup.object_id;
EXCEPTION WHEN foreign_key_violation THEN
  -- Object is still referenced elsewhere, ignore the error
  NULL;
END
$body$
  , 'Attempts to delete an object from the tracking system. Silently returns if the object is still referenced by other tables.'
  , 'object_reference__usage'
);

-- Trigger function for automatic object cleanup
SELECT __object_reference.create_function(
  '_object_reference._object_group__object__cleanup_trigger'
  , ''
  , 'trigger LANGUAGE plpgsql'
  , $body$
BEGIN
  PERFORM object_reference.object__cleanup(OLD.object_id);
  RETURN OLD;
END
$body$
  , 'Trigger function to automatically attempt cleanup of objects when removed from groups.'
);
CREATE TRIGGER object_group__object__cleanup
  AFTER DELETE ON _object_reference.object_group__object
  FOR EACH ROW
  EXECUTE FUNCTION _object_reference._object_group__object__cleanup_trigger();

/*
 * Drop "temporary" objects (see the note above CREATE SCHEMA __object_reference).
 */
DROP FUNCTION __object_reference.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text
);
DROP FUNCTION __object_reference.exec(
  sql text
);
DROP SCHEMA __object_reference;

ALTER EVENT TRIGGER zzz__object_reference_drop ENABLE;

-- vi: expandtab sw=2 ts=2
