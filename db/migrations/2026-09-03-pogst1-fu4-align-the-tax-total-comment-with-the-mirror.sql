-- PO-GST-1-fu4(2026-09-03)· 把线上那条列注释对齐成镜像里的措辞
--
-- 主迁移里那条 COMMENT 写的是「这张单开在【本刀】之前」。"本刀"在一条【会长期
-- 留在数据库里】的注释里是无主的:三个月后读它的人不知道是哪一刀。
-- 镜像里写的是「开在 PO-GST-1 之前」。db/gate.py 的【镜像 vs 线上】因此报漂移,
-- 而它报得对 —— 两边确实不是同一段字节。
-- 【改线上,不改镜像】因为镜像那一句才是对的。
BEGIN;
COMMENT ON COLUMN public.purchase_orders.tax_total_ccy IS
'PO-GST-1:这张单的税额合计,单据币种,= Σ 行 tax_amount_ccy(逐行取整后相加)。
★【estimated_total_ccy 仍然是【净额】,PO-GST-1 一个字节都没动它】★ 三样东西挂在那一列上:
审批级别(approval_level_for)、付款里程碑的百分比(purchase_order_payment_terms.percentage
的定义就是"对该 PO 的 estimated_total_ccy 而言")、现金预测(cash_forecast_data)。
把那一列改成含税,这三样会对【既有单据】同时移位。含税额 =
estimated_total_ccy + COALESCE(tax_total_ccy, 0),在读的那一侧相加。
**可空**:NULL = 这张单开在 PO-GST-1 之前,或 GST 未注册 —— 【不是零税】。';
COMMIT;
