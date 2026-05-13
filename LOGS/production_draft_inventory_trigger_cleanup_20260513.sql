-- Patch: Remove legacy production item triggers that write inventory_transactions during draft save
-- Reason: Production draft save failed with:
--   new row violates row-level security policy for table "inventory_transactions"
-- Draft item inserts must not write inventory. Inventory should be written only by confirm_production_document.
-- Apply in Supabase SQL Editor after review.

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT
            t.tgname,
            t.tgrelid::regclass AS table_name
        FROM pg_trigger t
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE t.tgrelid IN ('public.production_inputs'::regclass, 'public.production_outputs'::regclass)
          AND NOT t.tgisinternal
          AND pg_get_functiondef(p.oid) ILIKE '%inventory_transactions%'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', r.tgname, r.table_name);
    END LOOP;
END $$;

-- Optional verification after apply:
-- SELECT t.tgname, t.tgrelid::regclass AS table_name
-- FROM pg_trigger t
-- JOIN pg_proc p ON p.oid = t.tgfoid
-- WHERE t.tgrelid IN ('public.production_inputs'::regclass, 'public.production_outputs'::regclass)
--   AND NOT t.tgisinternal
--   AND pg_get_functiondef(p.oid) ILIKE '%inventory_transactions%';
