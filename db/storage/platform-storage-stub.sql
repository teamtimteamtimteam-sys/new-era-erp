-- db/storage/platform-storage-stub.sql —— a STAND-IN for the Supabase storage schema, for a LOCAL rebuild only (NOROLE-SURFACE, 2026-10-19).
--
-- ★ NEVER run this against a Supabase project. The platform owns the storage schema (owner supabase_storage_admin); this file would fail
--   there with "schema storage already exists" — and it should.
--
-- Why it exists: db/storage/buckets-and-policies.sql is the repo mirror of the 19 buckets and 52 storage.objects policies (Q11). A mirror
-- that can only be READ is not a mirror anybody has checked, so db/gate.py installs this stub into its throwaway local rebuild, then the
-- mirror on top of it, and:
--   · db/check_norole.py (verdict 7) compares the result with live — bucket columns and every policy's name, command, roles and expression;
--   · db/fixtures/274 exercises the policies as real RLS on real rows (read / upload / update / delete by code, refused without it,
--     delete refused for a file a record points at and allowed for an orphan).
-- The prelude (db/platform-prelude.sql) is unchanged: the rebuild proper still does not model storage. Only the columns the policies and
-- the fixtures touch are here, in the platform's names and types (measured on live 2026-10-19: storage.objects / storage.buckets).
-- What it does NOT model: the Storage API itself (bytes, signed URLs, upsert), storage.protect_delete (the platform refuses a direct SQL
-- DELETE unless storage.allow_delete_query is set — the API sets it), and the platform's own grants beyond the arwd that live gives
-- authenticated. Those are proved only on live (the HTTP proof in docs/handbacks/NOROLE-SURFACE.md).
CREATE SCHEMA storage;
GRANT USAGE ON SCHEMA storage TO authenticated, anon;

CREATE TABLE storage.buckets (
    id                 text PRIMARY KEY,
    name               text NOT NULL,
    owner              uuid,
    created_at         timestamptz DEFAULT now(),
    updated_at         timestamptz DEFAULT now(),
    public             boolean DEFAULT false,
    avif_autodetection boolean DEFAULT false,
    file_size_limit    bigint,
    allowed_mime_types text[],
    owner_id           text
);

CREATE TABLE storage.objects (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id        text REFERENCES storage.buckets (id),
    name             text,
    owner            uuid,
    created_at       timestamptz DEFAULT now(),
    updated_at       timestamptz DEFAULT now(),
    last_accessed_at timestamptz DEFAULT now(),
    metadata         jsonb,
    version          text,
    owner_id         text,
    user_metadata    jsonb,
    UNIQUE (bucket_id, name)
);

ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
-- live: authenticated = arwd on both (supabase_storage_admin grants it); RLS decides
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.buckets, storage.objects TO authenticated, anon;
