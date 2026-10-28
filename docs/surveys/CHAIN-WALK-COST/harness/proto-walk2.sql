-- LOCAL TIMING PROTOTYPE ONLY (never live): document_chain_walk2 — same contract as document_chain_walk,
-- but each hop is ONE set-based query per (target step, source key, target key) over the whole frontier,
-- and the edge SQL for a (from_table, to_table) pair is built once per walk from document_relations.
-- Same per-(source, target) limit (100, by code DESC), same shared-prefix filter, same self-exclusion, same filters.
CREATE OR REPLACE FUNCTION pg_temp.edge_sql(p_from_key text, p_to_key text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE f record; t record; e record; parts text[] := '{}'; v_sel text; v_where text := 'TRUE';
BEGIN
    SELECT d.table_name INTO f FROM public.document_types d WHERE d.key = p_from_key;
    SELECT d.key, d.table_name, d.prefix, d.label_column,
           (SELECT count(*) > 1 FROM public.document_types d2 WHERE d2.table_name = d.table_name) AS shared
      INTO t FROM public.document_types d WHERE d.key = p_to_key;
    v_sel := CASE WHEN t.label_column IS NULL THEN 'NULL::text' ELSE format('t.%I::text', t.label_column) END;
    FOR e IN SELECT * FROM public.document_relations dr WHERE dr.from_table = f.table_name AND dr.to_table = t.table_name LOOP
        IF e.kind = 'arm' THEN
            parts := parts || format('SELECT s.id AS src, t.id, t.code, %s AS label FROM unnest($1) s(id) '
                                     'CROSS JOIN LATERAL public.document_relation_arm_ids(%L, s.id) a JOIN public.%I t ON t.id = a.id',
                                     v_sel, e.via_table, e.to_table);
        ELSIF e.kind = 'bridge' THEN
            parts := parts || format('SELECT s.id AS src, t.id, t.code, %s AS label FROM public.%I s JOIN public.%I v ON v.%I = s.%I '
                                     'JOIN public.%I t ON t.%I = v.%I WHERE s.id = ANY ($1)',
                                     v_sel, e.from_table, e.via_table, e.via_from_column, e.from_column, e.to_table, e.to_column, e.via_to_column);
        ELSE
            parts := parts || format('SELECT s.id AS src, t.id, t.code, %s AS label FROM public.%I s JOIN public.%I t ON t.%I = s.%I '
                                     'WHERE s.id = ANY ($1)', v_sel, e.from_table, e.to_table, e.to_column, e.from_column);
        END IF;
    END LOOP;
    IF cardinality(parts) = 0 THEN RETURN NULL; END IF;
    IF t.shared THEN v_where := v_where || format(' AND u.code LIKE %L', t.prefix || '-%'); END IF;
    IF t.table_name = f.table_name THEN v_where := v_where || ' AND u.id <> u.src'; END IF;
    RETURN format('SELECT r.src, r.id, r.code, r.label FROM ('
                  ' SELECT d.*, row_number() OVER (PARTITION BY d.src ORDER BY d.code DESC) AS rn FROM ('
                  '  SELECT DISTINCT ON (u.src, u.id) u.src, u.id, u.code, u.label FROM (%s) u WHERE %s ORDER BY u.src, u.id) d) r'
                  ' WHERE r.rn <= 100', array_to_string(parts, ' UNION ALL '), v_where);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.document_chain_walk2(p_chain jsonb, p_step integer, p_key text, p_id uuid)
 RETURNS TABLE(step integer, key text, id uuid, code text, label text, href text)
 LANGUAGE plpgsql STABLE AS $function$
DECLARE
    v_steps jsonb := p_chain->'steps'; v_edges jsonb := p_chain->'edges'; n integer; dist integer[]; v_done boolean;
    j integer; e jsonb; a integer; b integer; t text; sk text; d record; r record; v_code text; v_label text; v_src integer[];
    f_step integer[]; f_key text[]; f_id uuid[]; f_code text[]; f_label text[]; v_pass integer; v_added integer; v_live text[];
    v_has boolean; v_ids uuid[]; v_sql text; v_cache jsonb := '{}'; v_asked text[] := '{}'; v_filter text;
BEGIN
    n := jsonb_array_length(v_steps);
    SELECT dt.table_name, dt.label_column INTO d FROM public.document_types dt WHERE dt.key = p_key;
    EXECUTE format('SELECT t.code::text, %s FROM public.%I t WHERE t.id = $1',
                   CASE WHEN d.label_column IS NULL THEN 'NULL::text' ELSE format('t.%I::text', d.label_column) END, d.table_name)
       INTO v_code, v_label USING p_id;
    IF v_code IS NULL OR NOT public.document_chain_step_admits(v_steps->p_step->>'filter', p_id) THEN RETURN; END IF;
    f_step := ARRAY[p_step]; f_key := ARRAY[p_key]; f_id := ARRAY[p_id]; f_code := ARRAY[v_code]; f_label := ARRAY[v_label];
    dist := array_fill(-1, ARRAY[n]); dist[p_step + 1] := 0;
    LOOP
        v_done := true;
        FOR e IN SELECT jsonb_array_elements(v_edges) LOOP
            a := (e->>0)::integer; b := (e->>1)::integer;
            IF dist[a + 1] >= 0 AND dist[b + 1] < 0 THEN dist[b + 1] := dist[a + 1] + 1; v_done := false;
            ELSIF dist[b + 1] >= 0 AND dist[a + 1] < 0 THEN dist[a + 1] := dist[b + 1] + 1; v_done := false; END IF;
        END LOOP;
        EXIT WHEN v_done;
    END LOOP;
    v_live := '{}';
    FOR t IN SELECT DISTINCT x FROM jsonb_array_elements(v_steps) st, jsonb_array_elements_text(st->'keys') x LOOP
        SELECT dt.table_name, dt.prefix, (SELECT count(*) > 1 FROM public.document_types d2 WHERE d2.table_name = dt.table_name) AS shared
          INTO d FROM public.document_types dt WHERE dt.key = t;
        IF NOT d.shared THEN v_live := v_live || t;
        ELSE
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I x WHERE x.code LIKE %L)', d.table_name, d.prefix || '-%') INTO v_has;
            IF v_has THEN v_live := v_live || t; END IF;
        END IF;
    END LOOP;
    FOR v_pass IN 1 .. n + 1 LOOP
        v_added := 0;
        FOR j IN SELECT g.i - 1 FROM generate_subscripts(dist, 1) AS g(i) WHERE dist[g.i] > 0 ORDER BY dist[g.i], g.i LOOP
            v_filter := v_steps->j->>'filter';
            SELECT coalesce(array_agg(DISTINCT x.s), '{}') INTO v_src
              FROM (SELECT CASE WHEN (ed->>0)::integer = j THEN (ed->>1)::integer ELSE (ed->>0)::integer END AS s
                      FROM jsonb_array_elements(v_edges) ed WHERE (ed->>0)::integer = j OR (ed->>1)::integer = j) x
             WHERE dist[x.s + 1] >= 0 AND dist[x.s + 1] <= dist[j + 1];
            FOR t IN SELECT jsonb_array_elements_text(v_steps->j->'keys') LOOP
                CONTINUE WHEN NOT (t = ANY (v_live));
                -- one batch per source key: every frontier row at a source step not yet asked for (j, its id, t)
                FOR sk IN SELECT DISTINCT u.k FROM unnest(f_step, f_key) u(s, k) WHERE u.s = ANY (v_src) LOOP
                    SELECT array_agg(DISTINCT u.i) INTO v_ids FROM unnest(f_step, f_key, f_id) u(s, k, i)
                     WHERE u.s = ANY (v_src) AND u.k = sk AND NOT ((j::text || '|' || sk || '|' || u.i::text || '|' || t) = ANY (v_asked));
                    CONTINUE WHEN v_ids IS NULL;
                    v_asked := v_asked || ARRAY(SELECT j::text || '|' || sk || '|' || x::text || '|' || t FROM unnest(v_ids) x);
                    IF sk = t THEN
                        FOR r IN SELECT DISTINCT ON (u.i) u.i AS id, u.c AS code, u.l AS label FROM unnest(f_key, f_id, f_code, f_label) u(k, i, c, l)
                                  WHERE u.k = sk AND u.i = ANY (v_ids) LOOP
                            CONTINUE WHEN EXISTS (SELECT 1 FROM unnest(f_step, f_id) AS h(hs, hi) WHERE h.hs = j AND h.hi = r.id);
                            IF public.document_chain_step_admits(v_filter, r.id) THEN
                                f_step := f_step || j; f_key := f_key || t; f_id := f_id || r.id; f_code := f_code || r.code; f_label := f_label || r.label;
                                v_added := v_added + 1;
                            END IF;
                        END LOOP;
                        CONTINUE;
                    END IF;
                    IF NOT v_cache ? (sk || '>' || t) THEN
                        v_cache := v_cache || jsonb_build_object(sk || '>' || t, pg_temp.edge_sql(sk, t));
                    END IF;
                    v_sql := v_cache ->> (sk || '>' || t);
                    CONTINUE WHEN v_sql IS NULL;
                    FOR r IN EXECUTE 'SELECT DISTINCT ON (q.id) q.id, q.code, q.label FROM (' || v_sql || ') q ORDER BY q.id' USING v_ids LOOP
                        CONTINUE WHEN EXISTS (SELECT 1 FROM unnest(f_step, f_id) AS h(hs, hi) WHERE h.hs = j AND h.hi = r.id);
                        IF public.document_chain_step_admits(v_filter, r.id) THEN
                            f_step := f_step || j; f_key := f_key || t; f_id := f_id || r.id; f_code := f_code || r.code; f_label := f_label || r.label;
                            v_added := v_added + 1;
                        END IF;
                    END LOOP;
                END LOOP;
            END LOOP;
        END LOOP;
        EXIT WHEN v_added = 0;
    END LOOP;
    RETURN QUERY SELECT u.st, u.k, u.i, u.c, u.l, public.document_detail_href(u.k, u.i)
      FROM unnest(f_step, f_key, f_id, f_code, f_label) AS u(st, k, i, c, l) ORDER BY u.st, u.c DESC;
END;
$function$;
