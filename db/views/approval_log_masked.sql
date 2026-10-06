-- db/views/approval_log_masked.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):审批留痕的遮蔽伴生视图。
-- 【遮什么】amount_ccy 与 amount_base —— 工资申请那一行是一期的工资合计(要 data.view_pay),医疗报销那一行是报销金额
--   (要 data.view_health,或那张报销单就是读者本人的)。其余种类原样给。判据住在 approval_log_amount_visible,
--   change_log_mask_rules 的 apr_amount 规则调的是同一支。
-- ★ U1-B(2026-10-05):note 也遮 —— 医疗报销那一行的说明是健康的字(approval_log_note_visible);金额那两列多认一种:
--   工资分录的冲销申请(journal_request,approval_log_amount_visible 的新一支)。
-- 【行谓词】approval_log_readable(subject_type) —— 与基表那条策略调同一支函数(属主视图绕过 RLS,所以这里必须再问一次)。
-- 【列】基表的每一列都在这里(colgrant:一张表有了 _masked 伴生视图,它的每一列都必须出现在视图里)。

CREATE VIEW public.approval_log_masked WITH (security_invoker = off) AS
 SELECT id,
    seq,
    subject_type,
    subject_id,
    subject_code,
    decision,
    level,
    actor_user_id,
    decided_at,
        CASE
            WHEN approval_log_note_visible(subject_type, subject_id) THEN note
            ELSE NULL::text
        END AS note,
        CASE
            WHEN approval_log_amount_visible(subject_type, subject_id) THEN amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
    currency,
    fx_rate,
        CASE
            WHEN approval_log_amount_visible(subject_type, subject_id) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    is_reconstructed,
    reconstruction_note,
    created_at,
    self_decided
   FROM approval_log
  WHERE approval_log_readable(subject_type);

COMMENT ON VIEW public.approval_log_masked IS
    'U1-A(UNBLOCK-1 Q8 · Q10):审批留痕的遮蔽伴生视图。工资申请那一行的金额要 data.view_pay,医疗报销那一行的金额要 data.view_health 或本人;判据在 approval_log_amount_visible。行谓词 approval_log_readable 与基表策略同一支函数。';

GRANT SELECT ON public.approval_log_masked TO authenticated;
