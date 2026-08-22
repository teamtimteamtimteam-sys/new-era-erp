CREATE OR REPLACE FUNCTION public.guard_assay_basis_stated()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 【只在 INSERT 上说话】这一条是整个设计的关键,不是实现细节:
    -- assay_results 的历史行会被 apply/unapply 例行改动(改的是【别人】那一行:
    -- `WHERE id = v_prior`),而历史行【没有】基准也永远补不出来。
    -- 若这道判断也管 UPDATE,第一次复检就会把所有旧化验单冻死 ——
    -- 那正是 PROC-5 在 materials 上实测到的那一幕(八行至今改不动)。
    IF NEW.weight_basis IS NULL THEN
        RAISE EXCEPTION 'ASSAY_BASIS_REQUIRED|%', COALESCE(NEW.code, '(未编号)')
          USING HINT = '一份没有说明重量基准的化验单,事后没有任何办法还原它按的是湿基还是干基。在录入界面上选「收到时(湿基)」或「烘干后(干基)」。';
    END IF;
    RETURN NEW;
END;
$fn$

;
