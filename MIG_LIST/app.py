import streamlit as st
import pandas as pd
from datetime import datetime

st.set_page_config(page_title="MIG_TAB_LIST Generator", layout="wide")

st.title("MIG_TAB_LIST SQL Generator")
st.caption("Upload Excel to generate INSERT SQL for DBADM.MIG_TAB_LIST")

# ============================================================
# 1. Template download
# ============================================================
with open("template/MIG_TAB_LIST_TEMPLATE.xlsx", "rb") as f:
    st.download_button(
        label="Download Excel Template",
        data=f,
        file_name="MIG_TAB_LIST_TEMPLATE.xlsx",
        mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )

st.divider()

# ============================================================
# 2. Excel upload
# ============================================================
uploaded_file = st.file_uploader("Upload Excel (.xlsx)", type=["xlsx"])

if uploaded_file is None:
    st.info("Please upload an Excel file to proceed.")
    st.stop()

df = pd.read_excel(uploaded_file, dtype=str)
df.columns = df.columns.str.strip().str.upper()

# --- Column check ---
REQUIRED_COLS = ["OWNER", "TABLE_NAME"]
ALL_COLS = ["OWNER", "TABLE_NAME", "WHERE_COL1", "PRE1", "WHERE_COL2", "PRE2"]

for col in REQUIRED_COLS:
    if col not in df.columns:
        st.error(f"Required column missing: {col}")
        st.stop()

# Add missing optional columns
for col in ALL_COLS:
    if col not in df.columns:
        df[col] = None

df = df[ALL_COLS]
for col in ALL_COLS:
    df[col] = df[col].apply(lambda x: x.strip() if isinstance(x, str) and x.strip() != "" else None)

# ============================================================
# 3. Data validation
# ============================================================
errors = []
warnings = []

for idx, row in df.iterrows():
    row_num = idx + 2  # Excel row (header=1)

    # Required check
    if row["OWNER"] is None:
        errors.append(f"Row {row_num}: OWNER is empty")
    if row["TABLE_NAME"] is None:
        errors.append(f"Row {row_num}: TABLE_NAME is empty")

    # WHERE_COL1 / PRE1 pair check
    if row["WHERE_COL1"] is not None and row["PRE1"] is None:
        warnings.append(f"Row {row_num}: WHERE_COL1 exists but PRE1 is empty")
    if row["WHERE_COL1"] is None and row["PRE1"] is not None:
        warnings.append(f"Row {row_num}: PRE1 exists but WHERE_COL1 is empty")

    # WHERE_COL2 / PRE2 pair check
    if row["WHERE_COL2"] is not None and row["PRE2"] is None:
        warnings.append(f"Row {row_num}: WHERE_COL2 exists but PRE2 is empty")
    if row["WHERE_COL2"] is None and row["PRE2"] is not None:
        warnings.append(f"Row {row_num}: PRE2 exists but WHERE_COL2 is empty")

    # COL2 without COL1
    if row["WHERE_COL1"] is None and row["WHERE_COL2"] is not None:
        warnings.append(f"Row {row_num}: WHERE_COL2 exists but WHERE_COL1 is empty")

# Duplicate check
dup = df.dropna(subset=["OWNER", "TABLE_NAME"]).duplicated(subset=["OWNER", "TABLE_NAME"], keep=False)
if dup.any():
    dup_rows = df[dup][["OWNER", "TABLE_NAME"]].drop_duplicates()
    for _, r in dup_rows.iterrows():
        errors.append(f"Duplicate: {r['OWNER']}.{r['TABLE_NAME']}")

# --- Display validation result ---
if errors:
    st.subheader("Validation Errors")
    for e in errors:
        st.error(e)

if warnings:
    st.subheader("Validation Warnings")
    for w in warnings:
        st.warning(w)

# ============================================================
# 4. Preview
# ============================================================
st.subheader(f"Preview ({len(df)} rows)")

# Build WHERE condition preview
def build_where(row):
    w1 = row["WHERE_COL1"] if pd.notna(row["WHERE_COL1"]) else None
    p1 = row["PRE1"] if pd.notna(row["PRE1"]) else None
    w2 = row["WHERE_COL2"] if pd.notna(row["WHERE_COL2"]) else None
    p2 = row["PRE2"] if pd.notna(row["PRE2"]) else None
    if w1 and p1 and w2 and p2:
        return f"WHERE {w1} >= '{p1}' AND {w2} < '{p2}'"
    elif w1 and p1:
        return f"WHERE {w1} >= '{p1}'"
    else:
        return "(full export)"

preview_df = df.copy()
preview_df["WHERE_CONDITION"] = preview_df.apply(build_where, axis=1)

def highlight_generated(row):
    styles = [""] * (len(row) - 1)
    styles.append("background-color: #d4edda; color: #155724; font-weight: bold")
    return styles

styled_df = preview_df.style.apply(highlight_generated, axis=1)
st.dataframe(styled_df, use_container_width=True, hide_index=True)

if errors:
    st.error("Please fix errors before generating SQL.")
    st.stop()

# ============================================================
# 5. SQL generation
# ============================================================
st.divider()
st.subheader("Generate SQL")

include_truncate = st.checkbox("Include TRUNCATE statement", value=True)

def to_sql_value(val):
    if val is None or pd.isna(val):
        return "NULL"
    return f"'{val}'"

def generate_sql():
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = []
    lines.append(f"-- Generated by MIG_LIST")
    lines.append(f"-- Date: {now}")
    lines.append(f"-- Total: {len(df)} rows")
    lines.append("")

    if include_truncate:
        lines.append("TRUNCATE TABLE DBADM.MIG_TAB_LIST;")
        lines.append("")

    for _, row in df.iterrows():
        vals = ", ".join([
            to_sql_value(row["OWNER"]),
            to_sql_value(row["TABLE_NAME"]),
            to_sql_value(row["WHERE_COL1"]),
            to_sql_value(row["PRE1"]),
            to_sql_value(row["WHERE_COL2"]),
            to_sql_value(row["PRE2"]),
        ])
        lines.append(
            f"INSERT INTO DBADM.MIG_TAB_LIST (OWNER, TABLE_NAME, WHERE_COL1, PRE1, WHERE_COL2, PRE2)"
        )
        lines.append(f"VALUES ({vals});")
        lines.append("")

    lines.append("COMMIT;")
    return "\n".join(lines)

sql_text = generate_sql()

st.code(sql_text, language="sql")

st.download_button(
    label="Download SQL File",
    data=sql_text,
    file_name=f"MIG_TAB_LIST_{datetime.now().strftime('%Y%m%d_%H%M%S')}.sql",
    mime="text/plain",
)
