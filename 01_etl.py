"""
Learner Journey project - Step 1: ETL (extract, clean, load)

Reads the seven Open University Learning Analytics Dataset (OULAD) CSV files,
cleans and standardizes them, logs every cleaning rule and how many rows it
touched, and loads everything into one SQLite database (oulad.db).

Run from the project folder:
    python3 01_etl.py

Expects the raw CSVs in:  data/raw/
Writes:                    oulad.db, outputs/cleaning_log.csv
"""

import sqlite3
import time
from pathlib import Path

import pandas as pd

RAW = Path("data/raw")
DB = Path("oulad.db")
OUT = Path("outputs")
OUT.mkdir(exist_ok=True)

# OULAD marks some missing values with "?" and leaves others blank.
NA = ["?", ""]

log = []  # every cleaning rule ends up here, then in outputs/cleaning_log.csv


def note(table, rule, rows_affected, action):
    log.append({"table": table, "rule": rule, "rows_affected": int(rows_affected), "action": action})
    print(f"  [{table}] {rule}: {rows_affected:,} rows -> {action}")


def strip_text(df):
    """Trim stray spaces on every text column."""
    for col in df.select_dtypes(include=["object", "string"]).columns:
        df[col] = df[col].astype("string").str.strip()
    return df


def load(name, **kw):
    path = RAW / f"{name}.csv"
    if not path.exists():
        raise SystemExit(f"Missing {path}. Download OULAD and unzip the CSVs into data/raw/ first.")
    df = pd.read_csv(path, na_values=NA, keep_default_na=True, **kw)
    print(f"Loaded {name}: {len(df):,} rows, {df.shape[1]} columns")
    return strip_text(df)


def drop_exact_duplicates(df, table, key):
    before = len(df)
    df = df.drop_duplicates()
    note(table, "Exact duplicate rows", before - len(df), "removed")
    dup_keys = df.duplicated(subset=key, keep=False).sum()
    note(table, f"Rows sharing the key {key} after exact-dup removal", dup_keys, "checked (should be 0)")
    return df


t0 = time.time()
print("\n=== EXTRACT + CLEAN ===")

# ---------- courses ----------
courses = load("courses")
courses = drop_exact_duplicates(courses, "courses", ["code_module", "code_presentation"])

# ---------- assessments ----------
assessments = load("assessments")
assessments = drop_exact_duplicates(assessments, "assessments", ["id_assessment"])
note("assessments", "Missing assessment date (usually final exams)", assessments["date"].isna().sum(),
     "kept; exam date treated as end of course where needed")

# ---------- vle (course materials) ----------
vle = load("vle")
vle = drop_exact_duplicates(vle, "vle", ["id_site"])

# ---------- studentInfo ----------
info = load("studentInfo")
KEY = ["code_module", "code_presentation", "id_student"]
info = drop_exact_duplicates(info, "studentInfo", KEY)

# Known quirk: one deprivation band is written without the % sign ("10-20" vs "10-20%").
bad_band = info["imd_band"].notna() & ~info["imd_band"].str.endswith("%", na=False)
note("studentInfo", "imd_band written without % (e.g. '10-20')", bad_band.sum(), "standardized to 'x-y%'")
info.loc[bad_band, "imd_band"] = info.loc[bad_band, "imd_band"] + "%"

missing_imd = info["imd_band"].isna().sum()
note("studentInfo", "Missing imd_band", missing_imd, "labeled 'Unknown' (kept, not guessed)")
info["imd_band"] = info["imd_band"].fillna("Unknown")

# Outcome groups used everywhere downstream
info["completed"] = info["final_result"].isin(["Pass", "Distinction"]).astype(int)
info["withdrew"] = (info["final_result"] == "Withdrawn").astype(int)

# ---------- studentRegistration ----------
reg = load("studentRegistration")
reg = drop_exact_duplicates(reg, "studentRegistration", KEY)
note("studentRegistration", "Missing date_registration", reg["date_registration"].isna().sum(),
     "kept; excluded only from registration-timing analysis")

# Consistency check: does 'Withdrawn' agree with having an unregistration date?
chk = reg.merge(info[KEY + ["final_result"]], on=KEY, how="left")
w_no_date = ((chk["final_result"] == "Withdrawn") & chk["date_unregistration"].isna()).sum()
date_not_w = ((chk["final_result"] != "Withdrawn") & chk["date_unregistration"].notna()).sum()
note("studentRegistration", "Withdrawn but no unregistration date", w_no_date,
     "flagged; outcome kept, excluded from withdrawal-timing analysis")
note("studentRegistration", "Unregistration date but outcome is not Withdrawn", date_not_w,
     "flagged; final_result treated as source of truth")
unreg_before_reg = (reg["date_unregistration"] < reg["date_registration"]).sum()
note("studentRegistration", "Unregistered before registering (impossible)", unreg_before_reg,
     "flagged for review")

# ---------- studentAssessment ----------
sa = load("studentAssessment")
sa = drop_exact_duplicates(sa, "studentAssessment", ["id_assessment", "id_student"])
note("studentAssessment", "Missing score", sa["score"].isna().sum(), "kept as submitted-without-score")
note("studentAssessment", "Banked results (carried over from a previous attempt)", (sa["is_banked"] == 1).sum(),
     "excluded from progress analysis (not work done this run)")
orphan = ~sa["id_assessment"].isin(assessments["id_assessment"])
note("studentAssessment", "Submission for an assessment that doesn't exist", orphan.sum(), "removed")
sa = sa[~orphan]

print("\n=== LOAD ===")
if DB.exists():
    DB.unlink()  # rebuild from scratch every run, so the pipeline is repeatable
con = sqlite3.connect(DB)
for name, df in [("courses", courses), ("assessments", assessments), ("vle", vle),
                 ("student_info", info), ("student_registration", reg), ("student_assessment", sa)]:
    df.to_sql(name, con, index=False)
    print(f"  wrote {name}: {len(df):,} rows")

# studentVle is the big one (~10 million rows): stream it in chunks.
print("  streaming studentVle (this is the slow step - a minute or two)...")
path = RAW / "studentVle.csv"
total, neg_clicks, chunks = 0, 0, 0
for chunk in pd.read_csv(path, na_values=NA, chunksize=1_000_000):
    bad = chunk["sum_click"] <= 0
    neg_clicks += int(bad.sum())
    chunk = chunk[~bad]
    chunk.to_sql("student_vle", con, index=False, if_exists="append")
    total += len(chunk)
    chunks += 1
    print(f"    chunk {chunks}: {total:,} rows loaded")
note("studentVle", "Zero or negative click counts", neg_clicks, "removed")

print("\n=== MODEL (SQL) ===")
con.executescript("""
CREATE INDEX ix_vle_student ON student_vle(code_module, code_presentation, id_student);

-- One row per learner per week: how active were they?
CREATE TABLE vle_weekly AS
SELECT code_module, code_presentation, id_student,
       CAST((date + 1001) / 7 AS INTEGER) - 143 AS week,   -- floor(date/7); the offset keeps negative (pre-start) days correct
       SUM(sum_click)        AS clicks,
       COUNT(DISTINCT date)  AS active_days
FROM student_vle
GROUP BY 1, 2, 3, 4;

-- One row per learner per course run: engagement summary
CREATE TABLE engagement AS
SELECT code_module, code_presentation, id_student,
       MIN(date) AS first_active_day,
       MAX(date) AS last_active_day,
       SUM(sum_click) AS total_clicks,
       SUM(CASE WHEN date < 0 THEN sum_click ELSE 0 END)               AS clicks_before_start,
       SUM(CASE WHEN date BETWEEN 0 AND 27 THEN sum_click ELSE 0 END)  AS clicks_first_28_days,
       COUNT(DISTINCT CASE WHEN date BETWEEN 0 AND 27 THEN date END)   AS active_days_first_28
FROM student_vle
GROUP BY 1, 2, 3;

-- Progress: how many graded (non-exam) assessments each learner submitted this run
CREATE TABLE progress AS
SELECT a.code_module, a.code_presentation, s.id_student,
       COUNT(*)                          AS assessments_submitted,
       MAX(s.date_submitted)             AS last_submission_day
FROM student_assessment s
JOIN assessments a ON a.id_assessment = s.id_assessment
WHERE a.assessment_type <> 'Exam' AND s.is_banked = 0
GROUP BY 1, 2, 3;

CREATE TABLE assessments_available AS
SELECT code_module, code_presentation, COUNT(*) AS n_available
FROM assessments WHERE assessment_type <> 'Exam'
GROUP BY 1, 2;

-- The modeled table everything else reads from: one row per learner per course run
CREATE TABLE learners AS
SELECT i.*,
       c.module_presentation_length                 AS course_length_days,
       r.date_registration, r.date_unregistration,
       COALESCE(e.total_clicks, 0)                  AS total_clicks,
       COALESCE(e.clicks_before_start, 0)           AS clicks_before_start,
       COALESCE(e.clicks_first_28_days, 0)          AS clicks_first_28_days,
       COALESCE(e.active_days_first_28, 0)          AS active_days_first_28,
       e.first_active_day, e.last_active_day,
       COALESCE(p.assessments_submitted, 0)         AS assessments_submitted,
       aa.n_available                               AS assessments_available,
       p.last_submission_day
FROM student_info i
LEFT JOIN courses c               USING (code_module, code_presentation)
LEFT JOIN student_registration r  USING (code_module, code_presentation, id_student)
LEFT JOIN engagement e            USING (code_module, code_presentation, id_student)
LEFT JOIN progress p              USING (code_module, code_presentation, id_student)
LEFT JOIN assessments_available aa USING (code_module, code_presentation);
""")
con.commit()

n_learners = con.execute("SELECT COUNT(*) FROM learners").fetchone()[0]
n_info = len(info)
note("learners", "Row count check: learners table vs studentInfo", abs(n_learners - n_info),
     "mismatch count (should be 0 - a join that adds or drops rows is a bug)")
never = con.execute("SELECT COUNT(*) FROM learners WHERE total_clicks = 0").fetchone()[0]
note("learners", "Enrolled but never clicked anything in the course site", never, "kept; this is a finding, not an error")

con.close()
pd.DataFrame(log).to_csv(OUT / "cleaning_log.csv", index=False)
print(f"\nDone in {time.time() - t0:,.0f}s. Database: {DB}  |  Cleaning log: {OUT/'cleaning_log.csv'}")
