-- GO-4:一家公司不是它的名字 —— 登记号成为身份,名字降为提示
--
-- 【问题】suppliers / customers 上,唯一性只加在 code 上,而 code 是触发器生成的
-- 流水号 —— 它保证不了【同一家公司不被录两次】。legal_name 与 tax_id 上没有任何
-- 约束,写入时也没有任何规范化(实测:两张表 5 个触发器,是编号生成、状态流转、
-- updated_at 与授信历史,没有一个碰这两列)。一家公司录两次 = 两本分类账、
-- 两个余额、两个信用头寸,而账龄报表把两边都低估。
--
-- 【身份是登记号,不是名字 —— 这是本刀的那个决定】
-- "Acme Battery Recycling Pte Ltd" / "Acme Battery Recycling Pte. Ltd." /
-- "ACME BATTERY RECYCLING PTE LTD" 是同一家公司,而再怎么规范化标点也不能让名字
-- 变成可靠的键;反过来,两家【真正不同】的公司可以在不同法域用同一个商号。
--
-- 【为什么复用 tax_id,而不是新加一列 registration_no】
-- 新加坡的 UEN 就是税号;中国的统一社会信用代码同样既是登记号也是税号。
-- 两列装同一个事实,正是本刀要治的那个病。**字段已经在了,两张表都有。**
--
-- 【为什么是【部分】唯一索引,而不是 NOT NULL / CHECK】
-- 18 行里只有 2 行有 tax_id(供应商 1、客户 1)。要求必填就得给另外 16 行编造值,
-- 而"为了满足约束而编造值"是 D7 明令禁止的。更要命的是 CHECK ... NOT VALID:
-- **它在任何一次 UPDATE 上重查整行**,会把 4 家在册供应商冻住 —— PROC-5 为这一条
-- 付过账(8 行物料从 PROC-1 起改不动)。唯一【索引】没有这个性质:它不重查整行,
-- 只在索引列真的重复时才拒。
--
-- 【为什么是 tax_id 单列,而不是 (country, tax_id)】
-- **本节的初稿给的理由是错的,留下更正而不是改口。** 初稿写的是"NULL 在唯一索引里
-- 彼此不相等,所以 country 为空时那个组合会整个失效"。实测:`country` 在这两张表上
-- **都是 NOT NULL**,18 行全部有值 —— 那个失效在这里【不可能发生】。
-- 结论不变,正确的理由是另一个,而且可以被实验判别:
--   **同一家公司被录两次时,最容易一起敲错的就是国别。** 同一个 UEN、一次 'SG'
--   一次 'MY',按 (country, tax_id) 建索引会【双双通过】—— 而那两行正是本刀要防的
--   那一种重复。单列 tax_id 拒得掉。fixture 123 的 D 臂第三段跑的就是这个实验。
-- (UEN 与统一社会信用代码在实务上不会互撞,所以单列不会误伤。)
--
-- 【tax_id 必须大写化,这不是修饰】不大写的话,195800026c 与 195800026C 是两行,
-- 而整把刀赖以成立的那个键当场被大小写击穿。
--
-- 【规范化放在触发器里,不是只放在 app 里 —— GO-2 的教训】
-- authenticated 对这两张表【持表级 INSERT 授权】(实测),所以只写在服务端动作里的
-- 规范化会被直连 PostgREST 的写入整个绕过 —— 那时【存进去的值】与【比较用的值】
-- 分了家,正是 D3 点名要防的那种失效,只是从另一条路来的。
--
-- 【名字那一侧【不在】这里】近重复的名字只【警告】,不拦 —— 两家公司真的可以同名,
-- 而拦住一次正当的第二次录入,只会把人逼去绕开它。警告没法住在约束里(约束不会
-- "提醒你然后放行"),所以它在表单上,并且在那里写明了它只是建议。
-- **数据库这一侧执行的是登记号;名字那一侧是表单上的一句提醒。两种强度,分开说。**
--
-- 【实测的前置(施加之前跑的)】
--   · 规范化会改动的行数:**0**(现有 18 行本来就是规范形式)—— 下面那两条 UPDATE
--     因此是空操作,保留它们是为了让"存量已规范"成为【真的】而不是【碰巧的】。
--   · 唯一性冲突:**0 组**,索引可以直接建。
BEGIN;

-- ── 一、写入时规范化 ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.normalise_counterparty_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    -- 名字:去首尾空白 + 压掉内部连续空白。**不动大小写** ——
    -- 公司名的大小写是它自己的写法("Pte Ltd" vs "PTE LTD" 都是人写下的样子),
    -- 存的时候不该替人改;大小写只在【比较】时折叠(见 app 层的近重复提示)。
    IF NEW.legal_name IS NOT NULL THEN
        NEW.legal_name := regexp_replace(btrim(NEW.legal_name), '\s+', ' ', 'g');
    END IF;
    -- 登记号:去空白 + **大写**。空字符串落成 NULL ——
    -- 「没填」与「填了空」必须是同一件事,否则部分唯一索引会把一堆 '' 当成真值去比。
    IF NEW.tax_id IS NOT NULL THEN
        NEW.tax_id := upper(regexp_replace(btrim(NEW.tax_id), '\s+', '', 'g'));
        IF NEW.tax_id = '' THEN NEW.tax_id := NULL; END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.normalise_counterparty_identity() IS
'GO-4:suppliers / customers 写入时规范化 legal_name(去空白)与 tax_id(去空白+大写)。放在触发器而不是只放在服务端动作里,是因为 authenticated 对这两张表持表级 INSERT 授权,只写在 app 里的规范化会被直连写入绕过,而那会让【存进去的值】与【比较用的值】分家 —— 唯一性规则于是静静失效。';

DROP TRIGGER IF EXISTS trg_suppliers_normalise_identity ON public.suppliers;
CREATE TRIGGER trg_suppliers_normalise_identity
    BEFORE INSERT OR UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.normalise_counterparty_identity();

DROP TRIGGER IF EXISTS trg_customers_normalise_identity ON public.customers;
CREATE TRIGGER trg_customers_normalise_identity
    BEFORE INSERT OR UPDATE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.normalise_counterparty_identity();

-- ── 二、存量按同一条规矩落一遍(实测:0 行会变,故意保留)────────────────────
UPDATE public.suppliers
   SET legal_name = regexp_replace(btrim(legal_name), '\s+', ' ', 'g')
 WHERE legal_name IS DISTINCT FROM regexp_replace(btrim(legal_name), '\s+', ' ', 'g');
UPDATE public.suppliers
   SET tax_id = NULLIF(upper(regexp_replace(btrim(tax_id), '\s+', '', 'g')), '')
 WHERE tax_id IS DISTINCT FROM NULLIF(upper(regexp_replace(btrim(tax_id), '\s+', '', 'g')), '');
UPDATE public.customers
   SET legal_name = regexp_replace(btrim(legal_name), '\s+', ' ', 'g')
 WHERE legal_name IS DISTINCT FROM regexp_replace(btrim(legal_name), '\s+', ' ', 'g');
UPDATE public.customers
   SET tax_id = NULLIF(upper(regexp_replace(btrim(tax_id), '\s+', '', 'g')), '')
 WHERE tax_id IS DISTINCT FROM NULLIF(upper(regexp_replace(btrim(tax_id), '\s+', '', 'g')), '');

-- ── 三、身份键:部分唯一索引 ───────────────────────────────────────────────
-- 排除软删行:一家公司被软删之后,同一个登记号应当可以重新录入。
CREATE UNIQUE INDEX IF NOT EXISTS suppliers_tax_id_unique
    ON public.suppliers (tax_id) WHERE tax_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS customers_tax_id_unique
    ON public.customers (tax_id) WHERE tax_id IS NOT NULL AND deleted_at IS NULL;

COMMENT ON COLUMN public.suppliers.tax_id IS
'登记号/税号(新加坡 UEN、中国统一社会信用代码)。**这是这一行的身份**,不是名字 —— GO-4。写入时去空白并大写;非空且未软删的行上唯一。【不是必填】:18 行里只有 2 行有值,而为了满足约束去编造值是禁止的;必填这一步留给【批量导入那一刀】,因为那是真实主数据到场、而补做成本开始上升的时刻。';

COMMENT ON COLUMN public.customers.tax_id IS
'登记号/税号(新加坡 UEN、中国统一社会信用代码)。**这是这一行的身份**,不是名字 —— GO-4。写入时去空白并大写;非空且未软删的行上唯一。【不是必填】,理由同 suppliers.tax_id,必填留给批量导入那一刀。';

COMMIT;
