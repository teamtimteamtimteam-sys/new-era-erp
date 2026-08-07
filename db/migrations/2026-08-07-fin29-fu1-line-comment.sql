-- FIN-29-fu1(2026-08-07):把行注释也改到线上。
--
-- 【我漏的】FIN-29 给模板【头】的新列写了 COMMENT,却没有更新
-- payment_term_template_lines.fixed_amount_ccy 的旧注释 —— 那句话还停在 FIN-28,
-- 说"币种要等被抄到某张 PO 上才确定",而 FIN-29 之后它由模板头声明。
-- 镜像文件里改了,线上没改,于是【镜像跑到了线上前面】:判词【镜像 vs 线上】
-- 报了唯一一条差异,内容恰好就是这句注释的新旧两版。
--
-- 注释不是装饰:AGENTS.md 的 C2 明写"每个改名列的 COMMENT 都要说清它装的是什么币",
-- 而一句停在上一切的注释,与一句错的注释代价相同 —— 读的人照样得到错的信念。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin29-fu1-line-comment.sql

BEGIN;

COMMENT ON COLUMN public.payment_term_template_lines.fixed_amount_ccy IS
    '模板里该期的定额,币种由【模板头】payment_term_templates.currency 声明(FIN-29)。有定额腿就必须声明,而套用时只接受币种相同的采购单 —— 不换算。FIN-29 之前这一列没有币种可言:同一个模板套到 USD 单与 SGD 单上,同一个数字是两笔差着一个汇率的钱。FIN-28 前列名 fixed_amount_usd。';

COMMIT;
