
"""
Delete duplicates by crop_name, keeping one row per name.
Default keep-rule: keep the smallest id per crop_name.

Requires:
  pip install pymysql

Steps:
  1) Set DB config.
  2) Adjust TABLE_NAME, KEY_COL, NAME_COL if different.
  3) Choose KEEP_RULE: "smallest_id" | "largest_id"
  4) DRY_RUN=True to preview, False to actually delete.
"""

import pymysql

# ========== CONFIG ==========
DB_CONFIG = {
    "host": "centerbeam.proxy.rlwy.net",
    "port": 46160,
    "user": "root",
    "password": "FNpMDDIVKerGZAFgoaJHalKfOmELHkQq",
    "database": "railway",
    "cursorclass": pymysql.cursors.DictCursor,
}

TABLE_NAME = "commonAllergen"
KEY_COL = "id"
NAME_COL = "allergenCommonName"

# Keep rule: "smallest_id" (default) or "largest_id"
KEEP_RULE = "smallest_id"

# Safety: preview only unless set to False
DRY_RUN = False

# Optional toggles
CASE_INSENSITIVE = False          # treat 'Buckwheat' and 'buckwheat' as the same
USE_TIMESTAMP = False             # if True, keep newest by timestamp column
TIMESTAMP_COL = "created_at"      # used only if USE_TIMESTAMP=True

def main():
    order_dir = "ASC" if KEEP_RULE == "smallest_id" else "DESC"

    # Choose partition key (case sensitive vs insensitive)
    if CASE_INSENSITIVE:
        part_expr = f"LOWER({NAME_COL})"
        select_name = f"LOWER({NAME_COL}) AS name_key"
    else:
        part_expr = NAME_COL
        select_name = f"{NAME_COL} AS name_key"

    # Choose ordering (by id or timestamp)
    if USE_TIMESTAMP:
        order_clause = f"ORDER BY {TIMESTAMP_COL} DESC"
    else:
        order_clause = f"ORDER BY {KEY_COL} {order_dir}"

    cte = f"""
        WITH ranked AS (
            SELECT
                {KEY_COL} AS id,
                {select_name},
                ROW_NUMBER() OVER (PARTITION BY {part_expr} {order_clause}) AS rn
            FROM {TABLE_NAME}
        )
    """

    preview_sql = cte + """
        SELECT id, name_key, rn
        FROM ranked
        WHERE rn > 1
        ORDER BY name_key, id;
    """

    delete_sql = cte + f"""
        DELETE t
        FROM {TABLE_NAME} t
        JOIN ranked r ON r.id = t.{KEY_COL}
        WHERE r.rn > 1;
    """

    conn = pymysql.connect(**DB_CONFIG)
    try:
        with conn.cursor() as cur:
            # Use an explicit transaction
            conn.begin()

            print("Previewing duplicates that would be deleted...")
            cur.execute(preview_sql)
            rows = cur.fetchall()

            if not rows:
                print("✅ No duplicates found. Nothing to delete.")
                conn.rollback()
                return

            # Show a short sample
            for r in rows[:20]:
                print(f"  -> delete id={r['id']}  name={r['name_key']}  rn={r['rn']}")
            if len(rows) > 20:
                print(f"... and {len(rows) - 20} more")

            if DRY_RUN:
                print("\nDRY_RUN=True — no rows deleted. Set DRY_RUN=False to proceed.")
                conn.rollback()
            else:
                print("\nDeleting duplicates...")
                cur.execute(delete_sql)
                print(f"✅ Deleted {cur.rowcount} rows.")
                conn.commit()

    finally:
        conn.close()

if __name__ == "__main__":
    main()
