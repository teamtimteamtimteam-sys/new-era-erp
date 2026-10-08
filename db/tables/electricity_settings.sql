-- db/tables/electricity_settings.sql
-- MES-5a-2(2026-10-08,MES-0 §5.1 V25 · Q27;MES-5a Step 0 Q25 · Q32,Tim):【电费分摊的设定 —— 单行】。今天只有一样:V25。
--   shared_pool_rule —— Tim 定的【共用池怎么摊】的规则,一句话写下来。为空 = "Not yet set":
--     不计量的电与共用池电表(devices.equipment_id 为空的电表)量到的电,在每一次分摊里都留在间接费用 6200,不往各炉摊(Q25)。
--     有共用池电表、而这一格为空时,/settings/pending-values 上 V25 那一行出现(module.finance.view)。
--   ★【给了之后,本刀【不】按它摊】★ 怎么摊是 Tim 的规则本身,今天没有人说过 —— 本刀只把它记下、让待补的值那一行消失;
--     真正按它摊的那一步跟着规则一起建(交回 §6 的决定)。分摊页把这句话照直写出来,不让"已设"读成"已生效"。
--   由 module.finance.edit 经 set_electricity_shared_pool_rule 改;修改史在变更记录里(主语 electricity_settings,画在 /finance/electricity)。
--   RUNTIME CONFIG:引导一行、规则为空;Tim 填一次,线上就与本文件不同 —— 那是系统在正常工作。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.electricity_settings (
    id                boolean PRIMARY KEY DEFAULT true CHECK (id),
    shared_pool_rule  text CHECK (shared_pool_rule IS NULL OR btrim(shared_pool_rule) <> ''),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.electricity_settings IS
    'MES-5a-2:电费分摊的设定(单行)。shared_pool_rule = V25,Tim 定的共用池电怎么摊;为空时不计量的电与共用池电表量到的电都留在间接费用 6200。本刀只记下规则,不按它摊(按它摊的那一步跟着规则一起建)。module.finance.edit 经 set_electricity_shared_pool_rule 改。';
COMMENT ON COLUMN public.electricity_settings.shared_pool_rule IS
    'V25(MES-0 §5.1):共用池电表与不计量的电怎么摊。空 = Not yet set —— 一律留在 6200。由 Tim 在第一张电表接上之后的第一张电费单时给。';

INSERT INTO public.electricity_settings (id) VALUES (true);

CREATE TRIGGER trg_electricity_settings_updated_at
    BEFORE UPDATE ON public.electricity_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.electricity_settings ENABLE ROW LEVEL SECURITY;
-- 读:财务查看码(分摊页与待补的值那一行)。写只经函数。
CREATE POLICY "electricity_settings select by permission" ON public.electricity_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
GRANT SELECT ON public.electricity_settings TO authenticated;
REVOKE ALL ON public.electricity_settings FROM anon;
