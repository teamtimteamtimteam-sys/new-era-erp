-- 123 一家公司不是它的名字(GO-4)
--
-- 【这份 fixture 钉住的东西】
--   身份是【登记号】,由数据库执行;名字只是表单上的一句提醒,数据库【不管】。
--   两种强度必须都被断言,而且要分开断言 —— 否则一个"把名字也拦住"的实现
--   会通过所有关于 tax_id 的臂,同时悄悄把一次正当的第二次录入挡在门外。
--
-- 【F2 的一半在这里,另一半【不可能】在这里 —— 照直说】
-- 「近重复的名字会提醒、会引出既有拼法」是 **app 层**的行为(服务端动作 +
-- 表单),而 fixtures 是 SQL:它够不着。这里断言的是那件事的**数据库侧前提**——
-- **同名的第二行必须真的写得进去**(C 臂)。提醒本身的行为由
-- `scripts/check-near-duplicate.mjs` 覆盖,那也是这条比较逻辑
-- **第一次**有自动化覆盖(抽取之前它一份都没有,见该脚本抬头)。
--
-- 【为什么不给 tax_id 加 NOT NULL / CHECK】18 行里只有 2 行有值,补值就是编造;
-- 而 CHECK ... NOT VALID 会在任何一次 UPDATE 上重查整行,把在册供应商冻住 ——
-- PROC-5 为这一条付过账。用【部分唯一索引】没有这个性质。
--
-- 【为什么索引是 tax_id 单列,而不是 (country, tax_id)—— D 臂把它钉死】
-- **先纠正一个本刀自己说错过的理由。** 磨的时候(以及迁移抬头初稿里)给出的论据是
-- "Postgres 唯一索引里 NULL 彼此不相等,所以 country 为空时那个组合会整个失效"。
-- 那个论据在**这两张表上不成立**:实测 `country` 在 suppliers 与 customers 上
-- **都是 NOT NULL**,而且 18 行全部有值(SG 11 / CN 1 / SG 4 / UK 1 / US 1)。
-- 论据错了,结论仍然对,而正确的理由是可以被实验判别的那一个:
--   **同一家公司被录两次时,最可能一起错的就是国别。** 一个人把新加坡公司的
--   country 敲成 'MY',再把同一个 UEN 录进去 —— 按 (country, tax_id) 建索引,
--   这两行【双双通过】,而它们正是本刀要防的那一种重复。单列 tax_id 拒得掉。
-- D 臂第三段就是这个实验:同号、不同国别,必须仍然被拒。
--
-- 自带数据(README 第 2 条)。日期无关。
BEGIN;
DO $$
DECLARE
    v_n int; v_denied boolean; v_msg text;
    v_before_s int; v_before_c int; v_after_s int; v_after_c int;
    v_name text; v_tax text; v_id uuid; v_id2 uuid; v_mat uuid;
BEGIN
    SELECT count(*) INTO v_before_s FROM suppliers;
    SELECT count(*) INTO v_before_c FROM customers;

    -- ══════════ A · 前提:规范化【不许改动一个已经规范的名字】═════════════════
    -- 【这一臂第一版写错了,改法记在这里】它原本断言线上那一行
    -- 'Robert Bosch (South East Asia) Pte. Ltd.' 原样读得回来 —— 在线上跑得好好的,
    -- 而 gate 在【重建出来的空库】上跑它,那一行根本不存在,于是报了 <NULL>。
    -- 违反的是 README 第 2、4 条:**每个用例自带数据,绝不依赖时间态的业务行**。
    -- 「存量一行未变」本来就是一句关于【线上】的话,fixture 够不着;它由切次里的
    -- 线上探针回答(GO-4 报告里那一段:12 行供应商 / 6 行客户,45 张单据的对手方
    -- 全部解析得到,0 悬挂)。**fixture 这一侧改成断言那条真正会坏的性质:**
    -- 一个已经规范的名字,过一遍规范化必须【一个字节都不变】。
    -- 括号、点号、大小写全在里面 —— 一个顺手折大小写或吃掉标点的实现在这里当场红。
    INSERT INTO suppliers (legal_name, country, counterparty_type)
    VALUES ('ZZFIX123 Robert Bosch (South East Asia) Pte. Ltd.', 'SG', 'goods_supplier')
    RETURNING id, legal_name INTO v_id, v_name;
    IF v_name <> 'ZZFIX123 Robert Bosch (South East Asia) Pte. Ltd.' THEN
        RAISE EXCEPTION 'FIXTURE 123A 失败:一个【已经规范】的名字过一遍规范化必须一字不变 —— 期望「ZZFIX123 Robert Bosch (South East Asia) Pte. Ltd.」,实得「%」。规范化只该去空白,不该动大小写或标点:存的是人写下的样子', v_name;
    END IF;
    -- UPDATE 也走同一个触发器:改个无关字段不该顺手改掉名字
    UPDATE suppliers SET credit_rating = 'A' WHERE id = v_id RETURNING legal_name INTO v_name;
    IF v_name <> 'ZZFIX123 Robert Bosch (South East Asia) Pte. Ltd.' THEN
        RAISE EXCEPTION 'FIXTURE 123A 失败:改一个无关字段之后名字变了 —— 实得「%」', v_name;
    END IF;

    -- 【自带数据的引用完整性】单据认得出它的对手方,而且规范化之后仍然认得出。
    -- 【连物料也自带】上一版这里写的是 INSERT ... SELECT FROM materials,
    -- 在线上有行、在【重建出来的空库】上一行都选不到 —— 于是它【静悄悄插了 0 行】,
    -- 而下面那句 count 才把它暴露出来。**INSERT ... SELECT 插不到东西不会报错**,
    -- 与本仓库反复写的那条是同一个形状:空集不是"没问题"。
    -- 用到的字典值(battery_material / black_mass / end_of_life)是引导数据,重建库里有。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX123-MAT', 'fixture 123 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, supplier_id, material_id, quantity, remaining_qty, unit, arrival_date, status)
    VALUES ('ZZFIX123-IB', v_id, v_mat, 1, 1, 'kg', CURRENT_DATE, 'draft');
    SELECT count(*) INTO v_n
      FROM inbound_batches b JOIN suppliers s ON s.id = b.supplier_id
     WHERE b.code = 'ZZFIX123-IB' AND s.legal_name = 'ZZFIX123 Robert Bosch (South East Asia) Pte. Ltd.';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 123A 失败:自带的那张进料批应当解析得到它的供应商并读回同一个名字,实得 % 行', v_n;
    END IF;

    -- ══════════ B · 写入时规范化,而且【比较用的就是存进去的那个值】═══════════
    -- 写一种变体,拿另一种变体去撞 —— 这是 D3 的整个要点:
    -- 存的值与比较的值一旦分家,唯一性规则就静静失效了。
    INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
    VALUES ('  ZZFIX123   Alpha   Metals  Pte  Ltd  ', 'SG', 'goods_supplier', '  zzfix123-uen-a  ')
    RETURNING id, legal_name, tax_id INTO v_id, v_name, v_tax;
    IF v_name <> 'ZZFIX123 Alpha Metals Pte Ltd' THEN
        RAISE EXCEPTION 'FIXTURE 123B 失败:legal_name 应当在【写入时】去掉首尾与内部多余空白,实得「%」', v_name;
    END IF;
    IF v_tax <> 'ZZFIX123-UEN-A' THEN
        RAISE EXCEPTION 'FIXTURE 123B 失败:tax_id 应当在写入时去空白【并大写】,实得「%」—— 不大写的话 195800026c 与 195800026C 就是两行,而整把刀赖以成立的那个键当场被大小写击穿', v_tax;
    END IF;
    -- 空字符串必须落成 NULL,否则部分唯一索引会把一堆 '' 当成真值互撞
    INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
    VALUES ('ZZFIX123 Empty Tax', 'SG', 'goods_supplier', '   ') RETURNING tax_id INTO v_tax;
    IF v_tax IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 123B 失败:全是空白的 tax_id 应当落成 NULL(「没填」与「填了空」必须是同一件事),实得「%」', v_tax;
    END IF;

    -- ══════════ C · 名字【不是】身份:同名的第二行必须写得进去 ════════════════
    -- 【这一臂是"警告而不是拦截"的数据库侧前提】少了它,一个把名字也做成唯一键的
    -- 实现会通过下面每一条关于 tax_id 的断言,同时把一次正当的第二次录入挡在门外,
    -- 而那会把人逼去改拼法绕过 —— 造出的正是本刀要防的脏数据。
    -- 【正向臂包起来】不包的话,注入让它失败时冒出来的是数据库的原始 unique_violation,
    -- 而不是这一臂想说的那句话 —— 那样红得看不出抓到了什么。
    BEGIN
        INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
        VALUES ('zzfix123   ALPHA metals pte ltd', 'MY', 'goods_supplier', 'ZZFIX123-UEN-B')
        RETURNING id INTO v_id2;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FIXTURE 123C 失败:同名(仅大小写与空白不同)但【登记号不同】的第二家公司必须建得出来 —— 两家真正不同的公司可以同名,把名字做成唯一键会把一次正当的录入挡在门外,而那会把人逼去改拼法绕过。实际被拒:%', SQLERRM;
    END;
    IF v_id2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 123C 失败:同名但登记号不同的第二家公司必须建得出来 —— 两家真正不同的公司可以同名';
    END IF;
    SELECT count(*) INTO v_n FROM suppliers
     WHERE lower(regexp_replace(btrim(legal_name),'\s+',' ','g')) = 'zzfix123 alpha metals pte ltd';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 123C 失败:折叠之后同名的应当有 2 行,实得 %', v_n;
    END IF;

    -- ══════════ D · 身份【是】登记号:重复的 tax_id 必须被拒 ═════════════════
    v_denied := false;
    BEGIN
        INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
        VALUES ('ZZFIX123 Totally Different Name', 'SG', 'goods_supplier', 'ZZFIX123-UEN-A');
    EXCEPTION WHEN unique_violation THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 123D 失败:同一个 tax_id 的第二行必须被拒 —— 名字完全不同也不行,因为身份是登记号不是名字';
    END IF;
    -- 【大小写变体同样要撞上】—— B 臂证明了存的是大写,这一臂证明键真的因此生效
    v_denied := false;
    BEGIN
        INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
        VALUES ('ZZFIX123 Case Variant', 'SG', 'goods_supplier', '  zzfix123-uen-a  ');
    EXCEPTION WHEN unique_violation THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 123D 失败:登记号的【大小写/空白变体】必须撞上同一个键 —— 否则规范化没有真的接进唯一性';
    END IF;

    -- 【同一个登记号 + 不同国别,必须仍然被拒】这一臂钉死"不要按 (country, tax_id) 建索引"。
    -- 判别性在于:按那个组合建,下面两行会【双双通过】;按单列建,第二行被拒。
    -- 这不是一个假想的输入 —— 同一家公司被录两次时,最容易一起敲错的恰恰是国别。
    INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
    VALUES ('ZZFIX123 Country A', 'SG', 'goods_supplier', 'ZZFIX123-UEN-N');
    v_denied := false;
    BEGIN
        INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
        VALUES ('ZZFIX123 Country B', 'MY', 'goods_supplier', 'ZZFIX123-UEN-N');
    EXCEPTION WHEN unique_violation THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 123D 失败:同一个登记号配【不同国别】必须仍然被拒 —— 若索引建成 (country, tax_id) 这两行会双双通过,而"同一家公司录两次、国别敲错一次"正是最常见的那种重复';
    END IF;

    -- ══════════ E · 软删的行不占用登记号 ════════════════════════════════════
    -- 一家公司被软删之后,同一个登记号应当可以重新录入(否则删掉就再也建不回来)。
    UPDATE suppliers SET deleted_at = now() WHERE tax_id = 'ZZFIX123-UEN-A';
    v_id2 := NULL;
    BEGIN
        INSERT INTO suppliers (legal_name, country, counterparty_type, tax_id)
        VALUES ('ZZFIX123 Reborn', 'SG', 'goods_supplier', 'ZZFIX123-UEN-A') RETURNING id INTO v_id2;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FIXTURE 123E 失败:软删之后同一个登记号应当可以重新录入 —— 索引若不排除软删行,一家公司被删掉之后就再也建不回来了。实际被拒:%', SQLERRM;
    END;
    IF v_id2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 123E 失败:软删之后同一个登记号应当可以重新录入';
    END IF;

    -- ══════════ F · 客户侧同样成立(两张表是一条规矩,不是两条)════════════════
    INSERT INTO customers (legal_name, country, tax_id)
    VALUES ('  ZZFIX123   Beta  Trading  ', 'SG', ' zzfix123-cust-a ')
    RETURNING legal_name, tax_id INTO v_name, v_tax;
    IF v_name <> 'ZZFIX123 Beta Trading' OR v_tax <> 'ZZFIX123-CUST-A' THEN
        RAISE EXCEPTION 'FIXTURE 123F 失败:客户侧的规范化应当与供应商侧一致,实得「%」/「%」', v_name, v_tax;
    END IF;
    v_denied := false;
    BEGIN
        INSERT INTO customers (legal_name, country, tax_id)
        VALUES ('ZZFIX123 Another Name', 'SG', 'ZZFIX123-CUST-A');
    EXCEPTION WHEN unique_violation THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 123F 失败:客户侧重复的登记号同样必须被拒';
    END IF;
    -- 客户侧同名也必须放行
    INSERT INTO customers (legal_name, country, tax_id)
    VALUES ('zzfix123 beta trading', 'MY', 'ZZFIX123-CUST-B');

    -- ══════════ G · 存量没有被这一刀动过 ════════════════════════════════════
    -- 【ILIKE,不是 LIKE】C 臂刻意插了一行【小写】的同名变体,而那正是本臂第一版
    -- 漏掉的东西:'zzfix123 …' 不匹配 'ZZFIX123%',于是它被当成存量数了进去。
    SELECT count(*) INTO v_after_s FROM suppliers WHERE legal_name NOT ILIKE 'ZZFIX123%';
    SELECT count(*) INTO v_after_c FROM customers WHERE legal_name NOT ILIKE 'ZZFIX123%';
    IF v_after_s <> v_before_s OR v_after_c <> v_before_c THEN
        RAISE EXCEPTION 'FIXTURE 123G 失败:存量行数变了 —— 供应商 %→%,客户 %→%', v_before_s, v_after_s, v_before_c, v_after_c;
    END IF;
END $$;
ROLLBACK;
