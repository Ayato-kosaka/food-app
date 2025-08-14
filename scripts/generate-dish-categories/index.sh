#!/bin/bash
set -euo pipefail

# 流し方
# DATABASE_URL=postgresql://xxx bash scripts/generate-dish-categories/index.sh

# ========== SETTINGS ==========
WDQS_URL="https://query.wikidata.org/sparql"
PSQL_ARGS=()
PSQL_ARGS+=("$DATABASE_URL")
DB_SCHEMA="dev"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR="${WORKDIR}/../../data/dish_master_tmp"
DISHES_CSV="$(realpath "${TMPDIR}/dishes_pg.csv")"
VARIANTS_CSV="$(realpath "${TMPDIR}/variants.csv")"
mkdir -p "$TMPDIR"

echo "▼ Start generating dish categories..."

# ========== STEP 1: Get core dish info (QID, label, tags, etc.) ==========
echo "→ [1] Fetching dishes_with_tags from Wikidata..."

curl -sG "${WDQS_URL}" \
  --data-urlencode query@"${WORKDIR}/dishes_with_tags.rq" \
  -H "Accept: text/csv" \
  -H "User-Agent: food-app/0.1 (contact: you@example.com)" \
  -o "${TMPDIR}/dishes_raw.csv"

echo "✅ Raw dish data saved to ${TMPDIR}/dishes_raw.csv"

# ========== STEP 2: Preprocess CSV to PostgreSQL format ==========
echo "→ [2] Transforming CSV to PostgreSQL-compatible format..."

tr -d '\r' < "${TMPDIR}/dishes_raw.csv" | csvsql -d , --query "
SELECT
  dish AS id,
  labelEN AS label_en,
  '{}' AS labels,
  COALESCE(image, '') AS image_url,
  CASE WHEN origins  IS NULL OR origins  = '' THEN '{}' ELSE '{'||REPLACE(origins, '|', ',') ||'}' END AS origin,
  CASE WHEN cuisines IS NULL OR cuisines = '' THEN '{}' ELSE '{'||REPLACE(cuisines,'|', ',') ||'}' END AS cuisine,
  CASE WHEN tags     IS NULL OR tags     = '' THEN '{}' ELSE '{'||REPLACE(tags,    '|', ',') ||'}' END AS tags
FROM stdin
" > "${DISHES_CSV}"

echo "✅ Preprocessed to ${DISHES_CSV}"

# ========== STEP 3: Import dish_categories ==========
echo "→ [3] Importing into dish_categories table..."

psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 \
  -v schema="${DB_SCHEMA:-public}" <<SQL
SET search_path TO :"schema";

CREATE TEMP TABLE tmp_dishes (
  id TEXT,
  label_en TEXT,
  labels JSONB,
  image_url TEXT,
  origin TEXT[],
  cuisine TEXT[],
  tags TEXT[]
);

\copy tmp_dishes FROM '${DISHES_CSV}' CSV HEADER

\echo [psql] dup_count=
SELECT count(*) FROM (
  SELECT id FROM tmp_dishes GROUP BY id HAVING count(*) > 1
) s;

UPDATE tmp_dishes
SET image_url = ''
WHERE image_url IS NULL OR image_url = 'NULL';

-- 既存: tmp_dishes に \copy → 画像あり優先の1行に間引く
DROP TABLE IF EXISTS tmp_dishes_one;
CREATE TEMP TABLE tmp_dishes_one AS
SELECT DISTINCT ON (id)
       id, label_en, labels, image_url, origin, cuisine, tags
FROM tmp_dishes
ORDER BY id, (image_url = ''), image_url DESC;

-- 追加: label_en を小文字化したキーで重複排除（QID数値が最小を採用）
DROP TABLE IF EXISTS tmp_dishes_by_label;
CREATE TEMP TABLE tmp_dishes_by_label AS
WITH numbered AS (
  SELECT *,
         LOWER(label_en) AS label_key,
         REGEXP_REPLACE(id, '.*Q([0-9]+)$', '\1')::bigint AS qnum
  FROM tmp_dishes_one
)
SELECT DISTINCT ON (label_key)
       id, label_en, labels, image_url, origin, cuisine, tags
FROM numbered
ORDER BY label_key, qnum;  -- 小さいQIDが勝ち

DELETE FROM dish_category_variants;
DELETE FROM dish_categories;

INSERT INTO dish_categories
(id, label_en, labels, image_url, origin, cuisine, tags)
SELECT
  CASE
    WHEN id ~ '^http' THEN REGEXP_REPLACE(id, '.*/(Q[0-9]+)$', '\1')
    ELSE id
  END AS id,
  label_en,
  labels,
  image_url,
  COALESCE(origin,  ARRAY[]::text[]),
  COALESCE(cuisine, ARRAY[]::text[]),
  COALESCE(tags,    ARRAY[]::text[])
FROM tmp_dishes_by_label
ON CONFLICT (id) DO UPDATE
SET label_en = EXCLUDED.label_en,
    image_url = COALESCE(NULLIF(EXCLUDED.image_url, 'NULL'), ''),
    origin = EXCLUDED.origin,
    cuisine = EXCLUDED.cuisine,
    tags = EXCLUDED.tags,
    updated_at = now(),
    lock_no = dish_categories.lock_no + 1;
  \copy (SELECT id, label_en FROM dish_categories) TO '${TMPDIR}/dishes_final.csv' CSV HEADER
SQL

echo "✅ dish_categories updated."

# ========== STEP 4: Fetch multilingual labels ==========
echo "→ [4-1] Fetching multilingual labels from Wikidata..."

curl -sG "${WDQS_URL}" \
  --data-urlencode query@"${WORKDIR}/labels_lang.rq" \
  -H "Accept: text/csv" \
  -H "User-Agent: food-app/0.1 (contact: you@example.com)" \
  -o "${TMPDIR}/labels.csv"

echo "✅ Multilingual labels saved to ${TMPDIR}/labels.csv"

echo "→ [4-2] Applying multilingual labels to dish_categories..."

psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 \
  -v schema="${DB_SCHEMA:-public}" <<SQL
SET search_path TO :"schema";

-- labels.csv を受ける一時テーブル
CREATE TEMP TABLE tmp_labels_raw (
  id TEXT,
  lang TEXT,
  label TEXT
);

\copy tmp_labels_raw FROM '${TMPDIR}/labels.csv' CSV HEADER

-- ID 形式を dish_categories.id (= 'Q12345' など) に正規化
-- URLが入ってきたケースにも対応
DROP TABLE IF EXISTS tmp_labels_norm;
CREATE TEMP TABLE tmp_labels_norm AS
SELECT
  CASE
    WHEN id ~ '^http' THEN REGEXP_REPLACE(id, '.*/(Q[0-9]+)$', '\1')
    ELSE id
  END AS id,
  LOWER(lang) AS lang,
  label
FROM tmp_labels_raw
WHERE lang IS NOT NULL AND label IS NOT NULL AND label <> '';

-- 同一 (id,lang) の重複がある場合は、短いラベルを優先（任意の方針）
DROP TABLE IF EXISTS tmp_labels_dedup;
CREATE TEMP TABLE tmp_labels_dedup AS
SELECT DISTINCT ON (id, lang)
       id, lang, label
FROM tmp_labels_norm
ORDER BY id, lang, LENGTH(label), label;

-- lang -> label の JSONB に集約
DROP TABLE IF EXISTS tmp_labels_json;
CREATE TEMP TABLE tmp_labels_json AS
SELECT id, jsonb_object_agg(lang, label) AS labels
FROM tmp_labels_dedup
GROUP BY id;

-- dish_categories.labels を更新 (labels.csv の内容を優先して上書き)
UPDATE dish_categories d
SET labels = COALESCE(j.labels, '{}'::jsonb),
    updated_at = now()
FROM tmp_labels_json j
WHERE d.id = j.id;
SQL

echo "✅ Multilingual labels applied to dish_categories."

# ========== STEP 5: Generate variants with Python ==========
echo "→ [5] Generating surface forms (variants)..."

python3 "${WORKDIR}/generate_variants.py" \
        "${TMPDIR}/labels.csv" \
        "${TMPDIR}/dishes_final.csv" \
        > "${TMPDIR}/variants.csv"

echo "✅ Variants CSV generated: ${TMPDIR}/variants.csv"

# ========== STEP 6: Import dish_category_variants ==========
echo "→ [6] Importing into dish_category_variants table..."

psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 \
  -v schema="${DB_SCHEMA:-public}" <<SQL
SET search_path TO :"schema";
\copy dish_category_variants (id, dish_category_id, surface_form, source, created_at) \
  FROM '${VARIANTS_CSV}' CSV HEADER;
SQL

echo "✅ dish_category_variants inserted."

# ========== FINISH ==========
echo "🎉 Dish category master generation complete!"