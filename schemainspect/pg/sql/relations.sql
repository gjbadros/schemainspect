with extension_oids as (
  select
      objid
  from
      pg_depend d
  WHERE
      d.refclassid = 'pg_extension'::regclass and
      d.classid = 'pg_class'::regclass
), enums as (

  SELECT
    t.oid as enum_oid,
    n.nspname as "schema",
    t.typname as name
  FROM pg_catalog.pg_type t
       LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
       left outer join extension_oids e
         on t.oid = e.objid
  WHERE
    t.typcategory = 'E'
    and e.objid is null
    -- SKIP_INTERNAL and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
    -- SKIP_INTERNAL and n.nspname not like 'pg_temp_%' and n.nspname not like 'pg_toast_temp_%'
  ORDER BY 1, 2
),
enums_arrays as (
  SELECT
    t.oid as enum_array_oid,
    n.nspname as "schema",
    substring(t.typname from 2) as name
  FROM pg_catalog.pg_type t
       LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
       left outer join extension_oids e
         on t.oid = e.objid
  WHERE
    (t.typcategory = 'A' and t.typelem in (select enum_oid from enums)) and e.objid is null
    -- SKIP_INTERNAL and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
    -- SKIP_INTERNAL and n.nspname not like 'pg_temp_%' and n.nspname not like 'pg_toast_temp_%'
  ORDER BY 1, 2

),
r as (
    select
        c.relname as name,
        n.nspname as schema,
        c.relkind as relationtype,
        c.oid as oid,
        case when c.relkind in ('m', 'v') then
          pg_get_viewdef(c.oid)
        else null end
          as definition,
        (SELECT
              '"' || nmsp_parent.nspname || '"."' || parent.relname || '"' as parent
          FROM pg_inherits
              JOIN pg_class parent            ON pg_inherits.inhparent = parent.oid
              JOIN pg_class child             ON pg_inherits.inhrelid   = child.oid
              JOIN pg_namespace nmsp_parent   ON nmsp_parent.oid  = parent.relnamespace
              JOIN pg_namespace nmsp_child    ON nmsp_child.oid   = child.relnamespace
          where child.oid = c.oid)
        as parent_table,
        case when c.relpartbound is not null then
          pg_get_expr(c.relpartbound, c.oid, true)
        when c.relhassubclass is not null then
          pg_catalog.pg_get_partkeydef(c.oid)
        end
        as partition_def,
        c.relrowsecurity::boolean as rowsecurity,
        c.relforcerowsecurity::boolean as forcerowsecurity,
        c.relpersistence as persistence,
        c.relpages as page_size_estimate,
        c.reltuples as row_count_estimate
    from
        pg_catalog.pg_class c
        inner join pg_catalog.pg_namespace n
          ON n.oid = c.relnamespace
        left outer join extension_oids e
          on c.oid = e.objid
    where c.relkind in ('r', 'v', 'm', 'c', 'p')
    -- SKIP_INTERNAL and e.objid is null
    -- SKIP_INTERNAL and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
    -- SKIP_INTERNAL and n.nspname not like 'pg_temp_%' and n.nspname not like 'pg_toast_temp_%'
)
select
    r.relationtype,
    r.schema,
    r.name,
    r.definition as definition,
    a.attnum as position_number,
    a.attname as attname,
    a.attnotnull as not_null,
    a.atttypid::regtype AS datatype,
    a.attidentity != '' as is_identity,
    a.attidentity = 'a' as is_identity_always,
    -- PRE_12 false as is_generated,
    -- 12_ONLY a.attgenerated != '' as is_generated,
    (SELECT c.collname FROM pg_catalog.pg_collation c, pg_catalog.pg_type t
     WHERE c.oid = a.attcollation AND t.oid = a.atttypid AND a.attcollation <> t.typcollation) AS collation,
    pg_get_expr(ad.adbin, ad.adrelid) as defaultdef,
    r.oid as oid,
    format_type(atttypid, atttypmod) AS datatypestring,
    (e.enum_oid is not null or ea.enum_array_oid is not null) as is_enum,
    (case when e.enum_oid is not null then e.name
          when ea.enum_array_oid is not null then ea.name
     end) as enum_name,
    (case when e.enum_oid is not null then e.schema
          when ea.enum_array_oid is not null then ea.schema
     end) as enum_schema,
    pg_catalog.obj_description(r.oid) as comment,
    r.parent_table,
    r.partition_def,
    r.rowsecurity,
    r.forcerowsecurity,
    r.persistence,
    r.page_size_estimate,
    r.row_count_estimate
FROM
    r
    left join pg_catalog.pg_attribute a
        on r.oid = a.attrelid and a.attnum > 0
    left join pg_catalog.pg_attrdef ad
        on a.attrelid = ad.adrelid
        and a.attnum = ad.adnum
    left join enums e
      on a.atttypid = e.enum_oid
    left join enums_arrays ea
      on a.atttypid = ea.enum_array_oid
where a.attisdropped is not true -- FOR TESTING: and a.attname like 'cap%'
-- SKIP_INTERNAL and r.schema not in ('pg_catalog', 'information_schema', 'pg_toast')
-- SKIP_INTERNAL and r.schema not like 'pg_temp_%' and r.schema not like 'pg_toast_temp_%'
order by relationtype, r.schema, r.name, position_number;
