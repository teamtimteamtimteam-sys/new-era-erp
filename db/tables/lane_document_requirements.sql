-- db/tables/lane_document_requirements.sql
-- LOG-1a。镜像与 db/migrations/2026-08-19-log1a-*.sql 同源。

CREATE TABLE public.lane_document_requirements (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lane_id       uuid NOT NULL REFERENCES public.lanes (id),
    document_type text NOT NULL,
    regime        text,
    notes         text,
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.lane_document_requirements IS
'LOG-1a:某条航段上要哪些单据。**一行一种单据,法规(regime)只是它的一个属性** ——
Basel、OECD、各国口岸规定在这里都只是 regime 这一列里的一个字符串,**本刀不为任何一个具名法规建模**:
法规会变、会叠加、会按国家不同,把它写进 schema 就等于把一份会过期的法律抄进表结构里。
【一行都不预置】。清单由人按航段填 —— 一份猜出来的合规清单比没有清单坏,它会让"没人看过"读成"看过了、没问题"
(与 exec-views-plan.md 里"危废存储天数等牌照文本"同一条理由)。
【空清单是一个具名状态】:见 lanes.checklist_reviewed_at 与视图 lane_checklist_status。';

COMMENT ON COLUMN public.lane_document_requirements.regime IS
'LOG-1a:这份单据出自哪一套规矩(例如巴塞尔公约、OECD 决定、某国口岸要求)。**自由文本,故意不做 CHECK、不做枚举、不做外键。**
本刀不建模任何具名法规 —— 一个枚举会在下一次法规修订时变成谎言,而一条拦得住真实单据的检查比没有检查坏。';

ALTER TABLE public.lane_document_requirements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "lane_document_requirements select" ON public.lane_document_requirements
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.logistics.view'::text));
CREATE POLICY "lane_document_requirements write" ON public.lane_document_requirements
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.lane_document_requirements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
