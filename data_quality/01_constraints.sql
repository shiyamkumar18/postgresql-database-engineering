-- 01_constraints.sql
-- Pull a list of every constraint the schema enforces.
-- Useful for audits and for the data_quality writeup.

SELECT
    conrelid::regclass AS table_name,
    conname            AS constraint_name,
    CASE contype
        WHEN 'p' THEN 'PRIMARY KEY'
        WHEN 'u' THEN 'UNIQUE'
        WHEN 'f' THEN 'FOREIGN KEY'
        WHEN 'c' THEN 'CHECK'
        WHEN 'x' THEN 'EXCLUDE'
    END AS constraint_type,
    pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
ORDER BY conrelid::regclass::text, contype, conname;
