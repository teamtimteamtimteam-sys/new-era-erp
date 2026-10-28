DO $$
DECLARE p record; q text; w text; n int := 0;
BEGIN
  FOR p IN SELECT * FROM pg_policies WHERE schemaname='public' AND (qual ~ 'has_(any_)?permission\(' OR with_check ~ 'has_(any_)?permission\(') LOOP
    q := regexp_replace(p.qual, '(has_(any_)?permission\((''[^'']*''::text(\[\])?|ARRAY\[[^\]]*\])\))', '(SELECT \1)', 'g');
    w := regexp_replace(p.with_check, '(has_(any_)?permission\((''[^'']*''::text(\[\])?|ARRAY\[[^\]]*\])\))', '(SELECT \1)', 'g');
    IF q IS DISTINCT FROM p.qual OR w IS DISTINCT FROM p.with_check THEN
      EXECUTE format('ALTER POLICY %I ON public.%I %s %s', p.policyname, p.tablename,
         CASE WHEN q IS NOT NULL THEN format('USING (%s)', q) ELSE '' END,
         CASE WHEN w IS NOT NULL THEN format('WITH CHECK (%s)', w) ELSE '' END);
      n := n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'altered %', n;
END $$;
