-- SEARCH-4 · 迁移 B —— 关联搜索走的那些外键列上的索引
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【为什么建,以及【不是】为什么建】理由与 SEARCH-2b 迁移 A(39 条 trigram GIN)
-- 与迁移 C(22 条 recents 索引)**逐字同族:为将来的体量,不为今天的毫秒数。**
-- 39 张单据表今天合计 320 行,规划器一律 Seq Scan ——
-- ★ **本刀不报任何一个毫秒数**,前三刀都拒绝过,而它们是对的。
--
-- 实测(2026-09-13):`document_relations` 视图真正走到的连接列 **148** 条,
-- 其中【以该列打头的索引存在】**73** 条,★ **缺席 75 条** —— 就是下面这些。
-- 缺席的里面包括 `inbound_batches.supplier_id`:Acme 那条路走的正是它。
--
-- ★★ 勘察报的是「162 列 / 缺 84 条」,这里是「148 列 / 缺 75 条」——
--   **不是重开裁定,是分母掉了一层**,而差额逐条点得出来(AGENTS.md
--   「一个数被抄走时,它的分母掉了」那一条,SEARCH-2b 迁移 C 刚付过一次)。
--   勘察那个数是在【应用裁定 Q5 与 Q3 之前】量的:它把**操作人列**与
--   **被声明作废的那几条噪音边**也算进了连接列。两条裁定落地之后,
--   视图不再走这 9 条,于是它们不在这支迁移里:
--     shift_handovers.acknowledged_by · shift_handovers.incoming_employee_id ·
--     shift_handovers.outgoing_employee_id · task_history.changed_by ·
--     task_nodes.created_by · task_nodes.done_by · task_nodes.updated_by ·
--     task_participants.added_by · task_participants.removed_by
--   ☞ 九条全是 `*_by`(或那条被声明作废的交接班噪音桥)。**本仓库对
--     「先建着,回头用」付过账**,所以一条没有消费者的索引不在这里建。
--
-- 【破窗】纯增量:75 条索引。旧代码不读它们,也不可能被它们改变行为 ——
--   与迁移 A / C / D 同族,**不与迁移 B 同族**。
--
-- 【为什么不带谓词】可见性由 RLS 决定,不由索引决定。把可见性的一半塞进
--   索引谓词,就是把同一条规则写第二遍 —— 迁移 C 的抬头逐字同一句。

BEGIN;

CREATE INDEX IF NOT EXISTS assay_results_superseded_by_rel                       ON public.assay_results                    (superseded_by);
CREATE INDEX IF NOT EXISTS bank_transfers_journal_entry_id_rel                   ON public.bank_transfers                   (journal_entry_id);
CREATE INDEX IF NOT EXISTS bank_transfers_reversal_entry_id_rel                  ON public.bank_transfers                   (reversal_entry_id);
CREATE INDEX IF NOT EXISTS cash_forecasts_superseded_by_rel                      ON public.cash_forecasts                   (superseded_by);
CREATE INDEX IF NOT EXISTS certificates_of_destruction_replaced_by_cod_id_rel    ON public.certificates_of_destruction      (replaced_by_cod_id);
CREATE INDEX IF NOT EXISTS collection_chases_superseded_by_rel                   ON public.collection_chases                (superseded_by);
CREATE INDEX IF NOT EXISTS contract_grade_specs_material_id_rel                  ON public.contract_grade_specs             (material_id);
CREATE INDEX IF NOT EXISTS contract_volume_commitments_material_id_rel           ON public.contract_volume_commitments      (material_id);
CREATE INDEX IF NOT EXISTS credit_notes_entry_id_rel                             ON public.credit_notes                     (entry_id);
CREATE INDEX IF NOT EXISTS customer_statements_superseded_by_rel                 ON public.customer_statements              (superseded_by);
CREATE INDEX IF NOT EXISTS equipment_maintenance_capitalised_expense_id_rel      ON public.equipment_maintenance            (capitalised_expense_id);
CREATE INDEX IF NOT EXISTS equipment_maintenance_performed_by_employee_id_rel    ON public.equipment_maintenance            (performed_by_employee_id);
CREATE INDEX IF NOT EXISTS equipment_maintenance_performed_by_supplier_id_rel    ON public.equipment_maintenance            (performed_by_supplier_id);
CREATE INDEX IF NOT EXISTS expense_claims_expense_id_rel                         ON public.expense_claims                   (expense_id);
CREATE INDEX IF NOT EXISTS expenses_employee_id_rel                              ON public.expenses                         (employee_id);
CREATE INDEX IF NOT EXISTS expenses_journal_entry_id_rel                         ON public.expenses                         (journal_entry_id);
CREATE INDEX IF NOT EXISTS expenses_reversed_by_expense_rel                      ON public.expenses                         (reversed_by_expense);
CREATE INDEX IF NOT EXISTS fixed_asset_depreciation_journal_entry_id_rel         ON public.fixed_asset_depreciation         (journal_entry_id);
CREATE INDEX IF NOT EXISTS fixed_asset_depreciation_anchors_expense_id_rel       ON public.fixed_asset_depreciation_anchors (expense_id);
CREATE INDEX IF NOT EXISTS fixed_assets_disposal_journal_id_rel                  ON public.fixed_assets                     (disposal_journal_id);
CREATE INDEX IF NOT EXISTS freight_documents_container_id_rel                    ON public.freight_documents                (container_id);
CREATE INDEX IF NOT EXISTS freight_documents_journal_entry_id_rel                ON public.freight_documents                (journal_entry_id);
CREATE INDEX IF NOT EXISTS freight_documents_reversal_entry_id_rel               ON public.freight_documents                (reversal_entry_id);
CREATE INDEX IF NOT EXISTS freight_documents_supplier_id_rel                     ON public.freight_documents                (supplier_id);
CREATE INDEX IF NOT EXISTS gst_periods_corrects_period_id_rel                    ON public.gst_periods                      (corrects_period_id);
CREATE INDEX IF NOT EXISTS inbound_batch_metals_source_assay_id_rel              ON public.inbound_batch_metals             (source_assay_id);
CREATE INDEX IF NOT EXISTS inbound_batches_material_id_rel                       ON public.inbound_batches                  (material_id);
CREATE INDEX IF NOT EXISTS inbound_batches_pricing_formula_id_rel                ON public.inbound_batches                  (pricing_formula_id);
CREATE INDEX IF NOT EXISTS inbound_batches_supplier_id_rel                       ON public.inbound_batches                  (supplier_id);
CREATE INDEX IF NOT EXISTS invoices_entry_id_rel                                 ON public.invoices                         (entry_id);
CREATE INDEX IF NOT EXISTS journal_entries_reversed_by_rel                       ON public.journal_entries                  (reversed_by);
CREATE INDEX IF NOT EXISTS management_packs_superseded_by_rel                    ON public.management_packs                 (superseded_by);
CREATE INDEX IF NOT EXISTS medical_claims_expense_id_rel                         ON public.medical_claims                   (expense_id);
CREATE INDEX IF NOT EXISTS output_batch_metals_source_assay_id_rel               ON public.output_batch_metals              (source_assay_id);
CREATE INDEX IF NOT EXISTS output_batches_customer_id_rel                        ON public.output_batches                   (customer_id);
CREATE INDEX IF NOT EXISTS output_batches_material_id_rel                        ON public.output_batches                   (material_id);
CREATE INDEX IF NOT EXISTS payment_allocations_freight_document_id_rel           ON public.payment_allocations              (freight_document_id);
CREATE INDEX IF NOT EXISTS payments_customer_id_rel                              ON public.payments                         (customer_id);
CREATE INDEX IF NOT EXISTS payments_employee_id_rel                              ON public.payments                         (employee_id);
CREATE INDEX IF NOT EXISTS payments_journal_entry_id_rel                         ON public.payments                         (journal_entry_id);
CREATE INDEX IF NOT EXISTS payments_reversed_by_payment_rel                      ON public.payments                         (reversed_by_payment);
CREATE INDEX IF NOT EXISTS payments_supplier_id_rel                              ON public.payments                         (supplier_id);
CREATE INDEX IF NOT EXISTS payroll_lines_paid_journal_entry_id_rel               ON public.payroll_lines                    (paid_journal_entry_id);
CREATE INDEX IF NOT EXISTS payroll_periods_cpf_journal_entry_id_rel              ON public.payroll_periods                  (cpf_journal_entry_id);
CREATE INDEX IF NOT EXISTS payroll_periods_deductions_journal_entry_id_rel       ON public.payroll_periods                  (deductions_journal_entry_id);
CREATE INDEX IF NOT EXISTS payroll_periods_journal_entry_id_rel                  ON public.payroll_periods                  (journal_entry_id);
CREATE INDEX IF NOT EXISTS prepayment_applications_journal_entry_id_rel          ON public.prepayment_applications          (journal_entry_id);
CREATE INDEX IF NOT EXISTS processing_cost_entries_relief_expense_id_rel         ON public.processing_cost_entries          (relief_expense_id);
CREATE INDEX IF NOT EXISTS processing_cost_entries_remitted_journal_entry_id_rel ON public.processing_cost_entries          (remitted_journal_entry_id);
CREATE INDEX IF NOT EXISTS processing_inputs_inbound_batch_id_rel                ON public.processing_inputs                (inbound_batch_id);
CREATE INDEX IF NOT EXISTS processing_inputs_run_id_rel                          ON public.processing_inputs                (run_id);
CREATE INDEX IF NOT EXISTS processing_outputs_output_batch_id_rel                ON public.processing_outputs               (output_batch_id);
CREATE INDEX IF NOT EXISTS processing_outputs_run_id_rel                         ON public.processing_outputs               (run_id);
CREATE INDEX IF NOT EXISTS processing_runs_capitalization_entry_id_rel           ON public.processing_runs                  (capitalization_entry_id);
CREATE INDEX IF NOT EXISTS purchase_order_lines_asset_id_rel                     ON public.purchase_order_lines             (asset_id);
CREATE INDEX IF NOT EXISTS purchase_order_lines_material_id_rel                  ON public.purchase_order_lines             (material_id);
CREATE INDEX IF NOT EXISTS purchase_order_lines_pricing_formula_id_rel           ON public.purchase_order_lines             (pricing_formula_id);
CREATE INDEX IF NOT EXISTS purchase_orders_contract_id_rel                       ON public.purchase_orders                  (contract_id);
CREATE INDEX IF NOT EXISTS quote_lines_material_id_rel                           ON public.quote_lines                      (material_id);
CREATE INDEX IF NOT EXISTS quotes_converted_order_id_rel                         ON public.quotes                           (converted_order_id);
CREATE INDEX IF NOT EXISTS sales_order_lines_material_id_rel                     ON public.sales_order_lines                (material_id);
CREATE INDEX IF NOT EXISTS sales_orders_contract_id_rel                          ON public.sales_orders                     (contract_id);
CREATE INDEX IF NOT EXISTS sales_records_cogs_entry_id_rel                       ON public.sales_records                    (cogs_entry_id);
CREATE INDEX IF NOT EXISTS sales_records_customer_id_rel                         ON public.sales_records                    (customer_id);
CREATE INDEX IF NOT EXISTS shipment_lines_output_batch_id_rel                    ON public.shipment_lines                   (output_batch_id);
CREATE INDEX IF NOT EXISTS stocktake_lines_inbound_batch_id_rel                  ON public.stocktake_lines                  (inbound_batch_id);
CREATE INDEX IF NOT EXISTS stocktake_lines_output_batch_id_rel                   ON public.stocktake_lines                  (output_batch_id);
CREATE INDEX IF NOT EXISTS task_history_employee_id_rel                          ON public.task_history                     (employee_id);
CREATE INDEX IF NOT EXISTS task_participants_employee_id_rel                     ON public.task_participants                (employee_id);
CREATE INDEX IF NOT EXISTS tasks_owner_id_rel                                    ON public.tasks                            (owner_id);
CREATE INDEX IF NOT EXISTS wht_remittances_journal_entry_id_rel                  ON public.wht_remittances                  (journal_entry_id);
CREATE INDEX IF NOT EXISTS work_order_expected_outputs_material_id_rel           ON public.work_order_expected_outputs      (material_id);
CREATE INDEX IF NOT EXISTS work_order_lines_material_id_rel                      ON public.work_order_lines                 (material_id);
CREATE INDEX IF NOT EXISTS year_closes_closing_journal_id_rel                    ON public.year_closes                      (closing_journal_id);
CREATE INDEX IF NOT EXISTS year_closes_reversal_journal_id_rel                   ON public.year_closes                      (reversal_journal_id);

COMMIT;
