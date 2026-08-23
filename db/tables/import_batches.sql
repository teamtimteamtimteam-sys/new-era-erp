-- db/tables/import_batches.sql
-- IMPORT-1(2026-08-24):批量导入的日志。
--
-- 【它是一本日志,不是一套血缘】它回答的只有一个问题:「那个文件到底进去了没有」。
-- 「这一行是导入来的吗」**不许**从这里推导,也不许有任何东西按它去 JOIN 业务表。
--
-- 【上线前的清库:这张表【跟着一起清】——一个决定,不是遗漏】
-- 一条写着「装进 500 家供应商」的日志,如果活过了那 500 家供应商被删掉的那一刻,
-- 它就成了一条【比它的对象活得更久】的记录。它的价值在清库【之前】,而那份价值
-- 不会因为一起清掉而损失。这句话同时写在表注上 —— 写清库脚本的人在对象上就读得到。

CREATE TABLE public.import_batches (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    target_table  text        NOT NULL,
    file_name     text        NOT NULL,
    row_count     integer     NOT NULL,
    code_first    text        NOT NULL,
    code_last     text        NOT NULL,
    imported_at   timestamptz NOT NULL DEFAULT now(),
    imported_by   uuid,
    CONSTRAINT import_batches_row_count_check CHECK ((row_count > 0)),
    CONSTRAINT import_batches_target_known
        CHECK ((target_table = ANY (ARRAY['materials'::text, 'suppliers'::text, 'customers'::text,
                                          'employees'::text, 'departments'::text, 'storage_locations'::text])))
);

COMMENT ON TABLE public.import_batches IS
'一本【日志】,不是一套血缘。它回答的只有一个问题:「那个文件到底进去了没有」。

【它【不是】关于那些行的第二个事实来源】——「这一行是导入来的吗」不许从这里推导,
也不许有任何东西按它去 JOIN 业务表。它只记:谁、什么时候、哪张表、哪个文件、
多少行、编号从哪到哪。多一列都会让它开始被当成血缘用。

【上线前的清库:这张表【跟着一起清】,这是一个决定,不是遗漏】(IMPORT-1,2026-08-24)
一条写着「2026-09-02 装进 500 家供应商」的日志,如果活过了那 500 家供应商被删掉的
那一刻,它就变成了一条【比它的对象活得更久】的记录 —— 本仓库对这个形状点过很多次名。
它的价值在清库【之前】(那个文件落了没有),而那份价值不会因为一起清掉而损失。
**写清库脚本的人在这里就会读到这句话,不必先去翻文档。**';

COMMENT ON COLUMN public.import_batches.code_first IS '本批次里【字典序最小】的编号 —— 与 code_last 一起给人一个"这一批大概是哪一段"的把手,不用于任何推导。';
COMMENT ON COLUMN public.import_batches.code_last IS '本批次里【字典序最大】的编号。同上。';

ALTER TABLE public.import_batches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "import_batches select by permission" ON public.import_batches
    FOR SELECT TO authenticated USING (has_permission('action.bulk_import'::text));
-- 写入只走 SECURITY DEFINER 的 master_import_apply,所以这里【故意】没有 INSERT 策略。

REVOKE ALL ON public.import_batches FROM authenticated;
GRANT SELECT ON public.import_batches TO authenticated;
