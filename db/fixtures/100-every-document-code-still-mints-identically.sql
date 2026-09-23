-- ════════════════════════════════════════════════════════════════════════════
-- ★ PAY-REQ-1(2026-09-23):40 → 41 —— 新增 payment_request / PREQ(无洞,next_payment_request_code)。
--   它是新单据,没有"变换之前"的字面量可比;锚里那一条就是它今天的前缀。
-- fixture 100 —— 停止条件 (g):【每一个单据码仍然铸得一模一样】,逐前缀,40 个
-- ════════════════════════════════════════════════════════════════════════════
--
-- SEARCH-2b 的迁移 B 重写了 44 支函数体,把每一支里的前缀字面量换成
-- document_type_prefix('<key>')。这支 fixture 是那次重写的【行为侧证明】。
--
-- ★★★ 它【绝不调用触发器那条路】—— 而这一条不是洁癖,是一次实测 ★★★
--   9 支触发器铸码用的是 nextval,而 **nextval 不回滚**。线上自己带着证据:
--   supplier_code_seq 是 444 而 suppliers 里最大的是 0095 —— 349 个号被回滚掉的
--   活烧掉了,六条序列合计 1,177 个。
--   一支"调用旧路径看看它会产生什么"的 fixture,每跑一次就为 9 个有洞前缀各烧
--   一个号,而 db/gate.py 【重放】fixture —— 它会累积。
--   ☞ 所以:有洞的那 9 种读 pg_sequence_last_value(),它答同一个问题而不消耗。
--
-- ★★ 而那 9 种的下一个号【不是】MAX(code)+1 ★★
--   suppliers 存着的最大是 SUP-2026-0095,下一个铸出来的是 SUP-2026-0445。
--   任何按 max+1 算期望值的证明,这九种全错。本文件按 numbering 分支算。
--
-- ★ split_part(code,'-',3)::integer 在真实数据上【会抛】—— materials 里有一行 IB25。
--   既有的铸码函数活下来,只因为每一支都先 WHERE code LIKE 'PFX-year-%' 过滤。
--   第 5 臂在一张空表上重现这一幕,并断言过滤器还在。
--
-- ── 这支 fixture 证得了什么、证不了什么(照直写)────────────────────────────
--   证得了:40 个前缀逐个的【下一个号】与变换前相等;44 支函数体里没有一个
--           前缀字面量活下来;读不到前缀时铸码【抛】而不是铸出 NULL。
--   证不了:并发取号。两个会话同时取号的行为由 advisory lock / sequence 决定,
--           而这一刀一个字都没动它们 —— 但"没动"是 build.py 的逐字节断言给的,
--           不是这支 fixture 给的。
--
-- ★ 22 支是【真的调用了】的(20 支专职 + 参数化那支的两个前缀);另外 18 支
--   要么会烧号(9 支有洞的),要么埋在一支有大量副作用的业务函数体里(9 个内联
--   前缀),它们按公式算期望值并与登记表比对。这个分母写在这里,不藏着。
--
-- 运行:psql "$DSN" -X -v ON_ERROR_STOP=1 -f db/fixtures/100-*.sql
BEGIN;

DO $fixture$
DECLARE
    v_year    integer := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    v_month   date    := date_trunc('month', CURRENT_DATE)::date;
    v_quarter integer := EXTRACT(quarter FROM CURRENT_DATE)::integer;
    r         record;
    v_n       integer;
    v_txt     text;
    v_expect  text;
    v_actual  text;
    v_codes   text[] := '{}';
    v_bad     text[] := '{}';

    -- ★ 变换【之前】线上那 44 支函数体里的前缀字面量,逐个抄在这里。
    --   这是本文件与 document_types 各存一份的【第二份真相】:种子若漂了,
    --   这一臂当场红。抄它的时候库上还没有 document_types —— 它不可能是
    --   从种子里推出来的,这正是它有资格当锚的理由。
    ANCHOR constant text[][] := ARRAY[
        ['assay_result','ASY'],            ['collection_chase','CHASE'],
        ['cod','COD'],                     ['container','CTR'],
        ['credit_note','CN'],              ['employee','EMP'],
        ['expense_claim','CLM'],           ['fixed_asset','FA'],
        ['cash_forecast','FCST'],          ['leave_request','LV'],
        ['medical_claim','MC'],            ['payroll_period','PAY'],
        ['pricing_formula','PF'],          ['purchase_order','PO'],
        ['quote','QT'],                    ['sales_order','SO'],
        ['shipment','SHP'],                ['customer_statement','STMT'],
        ['traceability_report','TRC'],     ['work_order','WO'],
        ['contract','CON'],                ['customer','CUS'],
        ['inbound_batch','IN'],            ['material','MAT'],
        ['output_batch','OUT'],            ['processing_run','PROC'],
        ['stocktake','ST'],                ['supplier','SUP'],
        ['task','TASK'],                   ['invoice','INV'],
        ['management_pack','PACK'],        ['bank_statement','BS'],
        ['attendance_period','ATT'],       ['gst_period','GST'],
        ['journal_entry','JE'],            ['expense','EXP'],
        ['freight_document','FRT'],        ['wht_remittance','WHT'],
        ['payment_receipt','RCPT'],        ['payment_out','PMT'],
        ['payment_request','PREQ']
    ];

    -- 铸码的【形状】—— 与 numbering 是两件事,不要合并。
    --   numbering 说的是"号码之间有没有洞"(T1 的那一列);
    --   shape 说的是"下一个号怎么算出来"。PACK / ATT / GST / WHT 四种都是无洞的,
    --   而它们一个 MAX+1 都不用:两种按【月内第几份】,两种【纯粹由期间导出】。
    --   把它们塞进 MAX+1 的期望值公式,四种全错。
    SHAPE constant text[][] := ARRAY[
        ['assay_result','seq_year'],       ['collection_chase','seq_year'],
        ['cod','seq_year'],                ['container','seq_year'],
        ['credit_note','seq_year'],        ['employee','seq_year'],
        ['expense_claim','seq_year'],      ['fixed_asset','seq_year'],
        ['cash_forecast','seq_year'],      ['leave_request','seq_year'],
        ['medical_claim','seq_year'],      ['payroll_period','seq_year'],
        ['pricing_formula','seq_year'],    ['purchase_order','seq_year'],
        ['quote','seq_year'],              ['sales_order','seq_year'],
        ['shipment','seq_year'],           ['customer_statement','seq_year'],
        ['traceability_report','seq_year'],['work_order','seq_year'],
        ['invoice','seq_year'],            ['bank_statement','seq_year'],
        ['journal_entry','seq_year'],      ['expense','seq_year'],
        ['freight_document','seq_year'],   ['payment_receipt','seq_year'],
        ['payment_out','seq_year'],        ['payment_request','seq_year'],
        ['contract','nextval_year'],       ['customer','nextval_year'],
        ['inbound_batch','nextval_year'],  ['material','nextval_year'],
        ['output_batch','nextval_year'],   ['processing_run','nextval_year'],
        ['stocktake','nextval_year'],      ['supplier','nextval_year'],
        ['task','nextval_year'],
        ['management_pack','count_month'], ['wht_remittance','count_month'],
        ['attendance_period','period_month'],
        ['gst_period','period_quarter']
    ];

    -- 直接调用得了、而且【调用不留痕】的那 22 支:纯 SELECT + advisory lock。
    CALLABLE constant text[][] := ARRAY[
        ['assay_result','next_assay_code'],
        ['collection_chase','next_chase_code'],
        ['cod','next_cod_code'],
        ['container','next_container_code'],
        ['credit_note','next_credit_note_code'],
        ['employee','next_employee_code'],
        ['expense_claim','next_expense_claim_code'],
        ['fixed_asset','next_fixed_asset_code'],
        ['cash_forecast','next_forecast_code'],
        ['leave_request','next_leave_request_code'],
        ['medical_claim','next_medical_claim_code'],
        ['payroll_period','next_payroll_code'],
        ['pricing_formula','next_pricing_formula_code'],
        ['purchase_order','next_purchase_order_code'],
        ['quote','next_quote_code'],
        ['sales_order','next_sales_order_code'],
        ['shipment','next_shipment_code'],
        ['customer_statement','next_statement_code'],
        ['traceability_report','next_traceability_report_code'],
        ['work_order','next_work_order_code'],
        ['payment_request','next_payment_request_code']
    ];
BEGIN
    -- ══ 第 1 臂 · 登记表的形状 ══════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM document_types;
    IF v_n <> 41 THEN
        RAISE EXCEPTION 'FIXTURE 100/1 失败:document_types 应有 41 行,实有 %', v_n;
    END IF;
    SELECT count(DISTINCT prefix) INTO v_n FROM document_types;
    IF v_n <> 41 THEN
        RAISE EXCEPTION 'FIXTURE 100/1 失败:前缀不唯一(distinct %)', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM document_types WHERE numbering = 'gapped';
    IF v_n <> 9 THEN
        RAISE EXCEPTION 'FIXTURE 100/1 失败:有洞的应有 9 种,实有 %', v_n;
    END IF;
    -- 有洞的那 9 条序列必须真的存在 —— 一个打错的序列名会让期望值算在
    -- 一条不存在的序列上,而 pg_sequence_last_value 对不存在的对象直接抛。
    FOR r IN SELECT key, sequence_name FROM document_types WHERE numbering = 'gapped' LOOP
        IF to_regclass('public.' || r.sequence_name) IS NULL THEN
            RAISE EXCEPTION 'FIXTURE 100/1 失败:% 登记的序列 % 不存在', r.key, r.sequence_name;
        END IF;
    END LOOP;
    -- 登记的表也必须存在(8 张今天还没有行的表照样在册 —— 在册 ≠ 有行)。
    FOR r IN SELECT key, table_name FROM document_types LOOP
        IF to_regclass('public.' || r.table_name) IS NULL THEN
            RAISE EXCEPTION 'FIXTURE 100/1 失败:% 登记的表 % 不存在', r.key, r.table_name;
        END IF;
    END LOOP;

    -- ══ 第 2 臂 · 前缀锚 ════════════════════════════════════════════════════
    -- 40 个 key,逐个把 document_type_prefix() 读出来的值与【变换之前函数体里
    -- 那个字面量】比。这一臂红 = 种子与被它取代的那个字面量不是同一个东西。
    FOR v_n IN 1 .. array_length(ANCHOR, 1) LOOP
        v_actual := document_type_prefix(ANCHOR[v_n][1]);
        IF v_actual IS DISTINCT FROM ANCHOR[v_n][2] THEN
            RAISE EXCEPTION 'FIXTURE 100/2 失败:% 的前缀应是 %,登记表给的是 %',
                ANCHOR[v_n][1], ANCHOR[v_n][2], v_actual;
        END IF;
    END LOOP;
    IF array_length(ANCHOR, 1) <> 41 THEN
        RAISE EXCEPTION 'FIXTURE 100/2 失败:锚只有 % 条,不是 41', array_length(ANCHOR, 1);
    END IF;
    -- ★ 覆盖率本身是一条断言:登记表里若出现一个锚里没有的 key,这一臂必须红,
    --   而不是安静地不检查它。
    FOR r IN SELECT key FROM document_types LOOP
        IF NOT EXISTS (SELECT 1 FROM unnest(ANCHOR) WITH ORDINALITY t(x, i)
                        WHERE t.x = r.key AND i % 2 = 1) THEN
            RAISE EXCEPTION 'FIXTURE 100/2 失败:登记表里的 % 在锚里没有对应行', r.key;
        END IF;
    END LOOP;

    -- ══ 第 3 臂 · 逐前缀的【下一个号】,40 个,一个都不少 ════════════════════
    FOR v_n IN 1 .. array_length(SHAPE, 1) LOOP
        DECLARE
            k      text := SHAPE[v_n][1];
            shape  text := SHAPE[v_n][2];
            pfx    text;
            tbl    text;
            seqn   text;
            nextno integer;
        BEGIN
            SELECT prefix, table_name, sequence_name INTO pfx, tbl, seqn
              FROM document_types WHERE key = k;

            IF shape = 'seq_year' THEN
                -- MAX(split_part(code,'-',3))+1,【带着那道 LIKE 过滤】——
                -- 没有它,materials 里那行 IB25 会让 ::integer 当场抛。
                EXECUTE format(
                    'SELECT COALESCE(MAX(split_part(code, ''-'', 3)::integer), 0) + 1'
                    ' FROM public.%I WHERE code LIKE %L', tbl, pfx || '-' || v_year::text || '-%')
                INTO nextno;
                v_expect := pfx || '-' || v_year::text || '-' || LPAD(nextno::text, 4, '0');

            ELSIF shape = 'nextval_year' THEN
                -- ★ 不调用、不消耗:pg_sequence_last_value 答"下一个会是几"而不推进它。
                --   序列没被用过时它是 NULL,而那时 nextval 会给 1 —— COALESCE 就是这件事。
                EXECUTE format('SELECT COALESCE(pg_sequence_last_value(%L::regclass), 0) + 1',
                               'public.' || seqn) INTO nextno;
                v_expect := pfx || '-' || v_year::text || '-' || LPAD(nextno::text, 4, '0');

            ELSIF shape = 'count_month' THEN
                -- 同一个月可以有多份,第二份起带序号(freeze_management_pack / remit_wht)。
                EXECUTE format('SELECT COUNT(*) + 1 FROM public.%I WHERE period_month = %L',
                               tbl, v_month) INTO nextno;
                v_expect := pfx || '-' || to_char(v_month, 'YYYY-MM')
                            || CASE WHEN nextno > 1 THEN '-' || nextno::text ELSE '' END;

            ELSIF shape = 'period_month' THEN
                v_expect := pfx || '-' || to_char(v_month, 'YYYY-MM');

            ELSIF shape = 'period_quarter' THEN
                v_expect := pfx || '-' || to_char(CURRENT_DATE, 'YYYY') || '-Q' || v_quarter::text;

            ELSE
                RAISE EXCEPTION 'FIXTURE 100/3 失败:% 的形状 % 不认识', k, shape;
            END IF;

            -- 号码必须以【锚里那个字面量】开头 —— 这是 (g) 的那句话本身。
            IF left(v_expect, length(pfx) + 1) <> pfx || '-' THEN
                RAISE EXCEPTION 'FIXTURE 100/3 失败:% 算出来的 % 不以 %- 开头', k, v_expect, pfx;
            END IF;
            v_codes := v_codes || (k || ' → ' || v_expect);
        END;
    END LOOP;
    IF array_length(v_codes, 1) <> 41 THEN
        RAISE EXCEPTION 'FIXTURE 100/3 失败:只算出 % 个前缀的号,不是 41', array_length(v_codes, 1);
    END IF;

    -- ══ 第 4 臂 · 那 22 支【真的调用一遍】,与公式对上 ══════════════════════
    -- 纯 SELECT + advisory xact lock:调用不留痕,回滚干净。
    FOR v_n IN 1 .. array_length(CALLABLE, 1) LOOP
        DECLARE
            k   text := CALLABLE[v_n][1];
            fn  text := CALLABLE[v_n][2];
            pfx text;
            tbl text;
            nextno integer;
        BEGIN
            SELECT prefix, table_name INTO pfx, tbl FROM document_types WHERE key = k;
            EXECUTE format(
                'SELECT COALESCE(MAX(split_part(code, ''-'', 3)::integer), 0) + 1'
                ' FROM public.%I WHERE code LIKE %L', tbl, pfx || '-' || v_year::text || '-%')
            INTO nextno;
            v_expect := pfx || '-' || v_year::text || '-' || LPAD(nextno::text, 4, '0');
            EXECUTE format('SELECT public.%I(%L::date)', fn, CURRENT_DATE) INTO v_actual;
            IF v_actual IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'FIXTURE 100/4 失败:%() 给出 %,公式算的是 %', fn, v_actual, v_expect;
            END IF;
        END;
    END LOOP;
    -- 参数化那一支的两个前缀 —— 它本来就是 prefix-as-data 的先例,
    -- 这一刀改的是它的两个【调用方】(record_payment / reverse_payment)。
    FOREACH v_txt IN ARRAY ARRAY['payment_receipt', 'payment_out'] LOOP
        SELECT prefix INTO v_expect FROM document_types WHERE key = v_txt;
        v_actual := fin_next_payment_code(document_type_prefix(v_txt), CURRENT_DATE);
        SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_n
          FROM payments WHERE code LIKE v_expect || '-' || v_year::text || '-%';
        IF v_actual IS DISTINCT FROM v_expect || '-' || v_year::text || '-' || LPAD(v_n::text, 4, '0') THEN
            RAISE EXCEPTION 'FIXTURE 100/4 失败:fin_next_payment_code(%) 给出 %', v_txt, v_actual;
        END IF;
    END LOOP;

    -- ══ 第 5 臂 · 那道 LIKE 过滤还在(materials 里的 IB25 就是靠它活下来的)══
    -- 在一张空表上把那一幕重现一次:塞一行【不合形状】的 code,再取下一个号。
    -- 过滤器若被变换弄丢了,split_part(...)::integer 当场抛,这一臂红。
    INSERT INTO pricing_formulas (code, name) VALUES ('IB25', 'fixture 100 · 形状不合的历史码');
    INSERT INTO pricing_formulas (code, name)
    VALUES (document_type_prefix('pricing_formula') || '-' || v_year::text || '-0007',
            'fixture 100 · 把 MAX 分支顶到 7');
    v_actual := next_pricing_formula_code(CURRENT_DATE);
    v_expect := 'PF-' || v_year::text || '-0008';
    IF v_actual IS DISTINCT FROM v_expect THEN
        RAISE EXCEPTION 'FIXTURE 100/5 失败:有 IB25 与 0007 在表里时应给 %,实得 %', v_expect, v_actual;
    END IF;
    -- 逐支复核【所有】走 MAX+1 的函数体里那道过滤还在 —— 上面那一行只证了一支。
    --
    -- ★★ 扫之前先把 `--` 注释剥掉,而这一条是【这一臂第一版被咬过之后】写的 ★★
    --   第一版扫的是原文,于是 master_import_apply 被点了名 —— 它一支号都不取,
    --   它的 split_part 走的是 unnest 出来的数组、而且自带正则闸;
    --   命中它的是**它注释里抄着的一行** `split_part(code,'-',3)::integer`。
    --   AGENTS.md 记着这一族:「一句注释可以污染将来对它自己的计数」。
    --   ☞ 所以判据只看【会被执行的那些字节】。
    -- ★ 别名要认:next_fixed_asset_code 写的是 split_part(fa.code, …),
    --   一个只认裸 `code` 的判据会安静地漏掉它 —— 而漏掉不等于绿。
    v_n := 0;
    FOR r IN
        SELECT p.proname,
               regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g') AS def
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
    LOOP
        IF r.def ~ 'split_part\(\s*([a-z_]+\.)?code\M' THEN
            v_n := v_n + 1;
            IF r.def !~ '([a-z_]+\.)?code LIKE ' THEN
                v_bad := v_bad || r.proname;
            END IF;
        END IF;
    END LOOP;
    IF array_length(v_bad, 1) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 100/5 失败:这些函数按 split_part 取号却没有 LIKE 过滤:%', v_bad;
    END IF;
    -- ★ 覆盖率本身是一条断言:一个瞎掉的扫描器和一棵干净的树都打印"通过"。
    --   实测(2026-09-13,变换前后同一个数):30 支。少于 30 = 判据瞎了,不是变干净了。
    -- ★ PAY-REQ-1:30 → 31(next_payment_request_code)。
    IF v_n <> 31 THEN
        RAISE EXCEPTION 'FIXTURE 100/5 失败:按 MAX(split_part(code)) 取号的函数应有 31 支,这次只看见 % 支'
                        ' —— 判据瞎了,不是树干净了', v_n;
    END IF;

    -- ══ 第 6 臂 · 前缀字面量 40 / 0 ════════════════════════════════════════
    -- 40 个前缀只许活在 document_types 里。任何一支 public 函数体里再出现一个
    -- 前缀字面量,就是 T1 被绕过了 —— 它会安静地与登记表分家。
    v_bad := '{}';
    FOR r IN
        -- 同第 5 臂:只看会被执行的字节。注释里写着 'SUP-' 的一句话不是一次绕过。
        SELECT p.proname,
               regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g') AS def
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname <> 'document_type_prefix'
    LOOP
        FOR v_txt IN SELECT prefix FROM document_types LOOP
            IF r.def ~ ('''' || v_txt || '(-|'')') THEN
                v_bad := v_bad || (r.proname || ':' || v_txt);
            END IF;
        END LOOP;
    END LOOP;
    IF array_length(v_bad, 1) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 100/6 失败:前缀字面量活在种子之外:%', v_bad;
    END IF;

    -- ══ 第 7 臂 · 读不到就【抛】,不返回 NULL ═══════════════════════════════
    -- ★ 这一臂守的是本刀最贵的那个失败:RLS 把 document_types 挡住的时候,
    --   一个"读返回值"的实现会拿到 NULL,而 'X' || NULL 整体是 NULL ——
    --   铸出来的是一个 NULL 号,不是一次失败。所以它必须抛。
    BEGIN
        v_actual := document_type_prefix('这个 key 不存在');
        RAISE EXCEPTION 'FIXTURE 100/7 失败:未知 key 应当抛,却返回了 %', COALESCE(v_actual, '<NULL>');
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM NOT LIKE 'DOCUMENT_TYPE_PREFIX_MISSING|%' THEN
                RAISE;
            END IF;
    END;

    -- ══ 第 8 臂 · match_columns 里的每一列,authenticated 【真的 SELECT 得到】 ══
    -- ★★ 这一臂是 Tim 那条裁定的执行面,而它守的东西比它看起来重 ★★
    --   裁定是「页面上看得见的都要搜得到」。一个天真的"匹配所有文本列"面是
    --   170 列 / 31 张表,里面包含 employees 的 identity_no · work_pass_no ·
    --   work_email · work_phone —— 而那四列对 authenticated 是 REVOKE 掉的。
    --   一个持 module.hr.view 但没有 data.view_identity 的人,在页面上看得见
    --   legal_name、看不见 identity_no。若搜索匹配 identity_no,他就能
    --   **拿着一个身份证号确认它是谁的** —— 而那正是页面刻意扣住的映射。
    --   ☞ 搜索比页面【松】,同一条裁定禁止它。
    -- ★ 而这里的遮蔽是【列级】的(GRANT / _masked 视图),不是 RLS 的行级 ——
    --   所以「匹配 RLS 让你读到的一切」【不等于】「匹配页面给你看的一切」,
    --   而这一臂问的正是列级那一半。
    v_bad := '{}';
    v_n := 0;
    FOR r IN SELECT d.table_name, c AS col FROM document_types d, unnest(d.match_columns) c LOOP
        v_n := v_n + 1;
        IF NOT has_column_privilege('authenticated', ('public.' || r.table_name)::regclass,
                                    r.col, 'SELECT') THEN
            v_bad := v_bad || (r.table_name || '.' || r.col);
        END IF;
    END LOOP;
    IF array_length(v_bad, 1) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 100/8 失败:这些 match_columns 对 authenticated 没有 SELECT —— '
                        '搜索会匹配到页面刻意扣住的东西:%', v_bad;
    END IF;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 100/8 失败:一列都没检查到 —— 判据瞎了,不是登记表干净了';
    END IF;
    -- ★ 正面对照:这一臂【看得见收回】。没有这一格,上面那个"全部通过"
    --   可能只是因为 has_column_privilege 在这个库上恒为真。
    IF has_column_privilege('authenticated', 'public.employees'::regclass, 'identity_no', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 100/8 失败:employees.identity_no 对 authenticated 居然是 SELECT 得到的 —— '
                        '要么列级遮蔽被撤了,要么这一臂看的是错的东西';
    END IF;

    RAISE NOTICE 'FIXTURE 100 全部通过:40 个前缀逐个算出下一个号(其中 22 支真的调用过),前缀字面量种子外 0 处;match_columns 逐列 SELECT-granted。';
    RAISE NOTICE '  40 个号:%', array_to_string(v_codes, ' · ');
END
$fixture$;

ROLLBACK;
