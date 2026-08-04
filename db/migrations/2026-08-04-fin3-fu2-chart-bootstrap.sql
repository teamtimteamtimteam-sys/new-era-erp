-- db/migrations/2026-08-04-fin3-fu2-chart-bootstrap.sql
-- FIN-3 追问 2/3:
-- 1) 1400/2100(GST 进项/销项)翻为货币性 —— 对 IRAS 的定额债权/义务,名实相符;
--    今天纯 SGD、行为零变化,但别等别的东西开始读这个标签才改。
-- 2) 6600 停用 —— 7100/7110 之外的第三个汇兑桶只会被人顺手选错;历史留着,新账不许进。
-- 3) 非 is_system 的 15 个结构性科目进镜像种子(引导默认值,见 accounts.sql 尾段)——
--    此前全新重建只有 22 个科目、没有权益部分,配不平的库不算能用的安装。
--    本迁移不动线上那 16 行(已存在);种子只管全新安装。6600 故意不进种子。
BEGIN;
UPDATE public.accounts SET is_monetary = true WHERE code IN ('1400','2100');
UPDATE public.accounts SET is_active = false WHERE code = '6600';
COMMIT;
