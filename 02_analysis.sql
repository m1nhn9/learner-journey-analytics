-- Learner Journey project - Step 2: analysis queries
-- Every query reads the modeled table `learners` (one row per learner per course run)
-- or `vle_weekly`, both built by 01_etl.py.
-- 03_export.py runs each block below and saves it to outputs/<name>.csv
-- Each block starts with a line:  -- name: <query_name>

-- name: q0_overview
-- How big is this, and how does it end? (Laura's Q5: how many make it to the end)
SELECT final_result,
       COUNT(*) AS learners,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM learners), 1) AS pct
FROM learners
GROUP BY final_result
ORDER BY learners DESC;

-- name: q1_outcomes_by_course
-- Completion and withdrawal by course and run. Which courses lose the most people?
SELECT code_module, code_presentation,
       COUNT(*)                                   AS learners,
       ROUND(100.0 * AVG(completed), 1)           AS completion_pct,
       ROUND(100.0 * AVG(withdrew), 1)            AS withdrawal_pct,
       ROUND(100.0 * AVG(final_result = 'Fail'), 1) AS fail_pct
FROM learners
GROUP BY 1, 2
ORDER BY withdrawal_pct DESC;

-- name: q2_registration_timing
-- Laura's Q1 analog: how long between signing up and the course starting -
-- and does signing up late predict dropping out?
-- date_registration is days relative to course start (negative = before start).
SELECT CASE
         WHEN date_registration < -60 THEN '1. 60+ days before start'
         WHEN date_registration < -30 THEN '2. 31-60 days before'
         WHEN date_registration < 0   THEN '3. 1-30 days before'
         ELSE                              '4. On or after start day'
       END AS registered,
       COUNT(*)                         AS learners,
       ROUND(100.0 * AVG(withdrew), 1)  AS withdrawal_pct,
       ROUND(100.0 * AVG(completed), 1) AS completion_pct
FROM learners
WHERE date_registration IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- name: q3_withdrawal_timing
-- Laura's Q4: WHEN do people drop? Measured as % of the course already elapsed.
-- Only learners whose outcome is Withdrawn AND who have an unregistration date.
SELECT CASE
         WHEN date_unregistration < 0 THEN '1. Before the course started'
         WHEN 1.0 * date_unregistration / course_length_days < 0.25 THEN '2. First quarter'
         WHEN 1.0 * date_unregistration / course_length_days < 0.50 THEN '3. Second quarter'
         WHEN 1.0 * date_unregistration / course_length_days < 0.75 THEN '4. Third quarter'
         ELSE                                                             '5. Final quarter'
       END AS dropped_during,
       COUNT(*) AS withdrawals,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_withdrawals
FROM learners
WHERE withdrew = 1 AND date_unregistration IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- name: q3b_withdrawal_by_week
-- Same question, finer grain: withdrawals per course week (for the drop-off chart).
SELECT CAST((date_unregistration + 1001) / 7 AS INTEGER) - 143 AS week,
       COUNT(*) AS withdrawals
FROM learners
WHERE withdrew = 1 AND date_unregistration IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- name: q4_first_month_engagement
-- Laura's Q2 analog ("onboarding"): does activity in the first 4 weeks predict the outcome?
-- Learners with zero clicks are their own group; everyone else is split into quartiles.
WITH ranked AS (
  SELECT *,
         CASE WHEN clicks_first_28_days = 0 THEN 0
              ELSE NTILE(4) OVER (PARTITION BY (clicks_first_28_days > 0) ORDER BY clicks_first_28_days)
         END AS q
  FROM learners
)
SELECT CASE q WHEN 0 THEN '0. No activity in first 4 weeks'
              WHEN 1 THEN '1. Lowest quarter'
              WHEN 2 THEN '2. Second quarter'
              WHEN 3 THEN '3. Third quarter'
              ELSE        '4. Highest quarter' END AS first_month_activity,
       COUNT(*)                         AS learners,
       MIN(clicks_first_28_days)        AS min_clicks,
       MAX(clicks_first_28_days)        AS max_clicks,
       ROUND(100.0 * AVG(withdrew), 1)  AS withdrawal_pct,
       ROUND(100.0 * AVG(completed), 1) AS completion_pct
FROM ranked
GROUP BY q
ORDER BY q;

-- name: q4b_activity_before_start
-- Did logging in BEFORE day 1 (exploring the course early) go with better outcomes?
SELECT CASE WHEN clicks_before_start > 0 THEN 'Active before start' ELSE 'Not active before start' END AS pre_start,
       COUNT(*)                         AS learners,
       ROUND(100.0 * AVG(withdrew), 1)  AS withdrawal_pct,
       ROUND(100.0 * AVG(completed), 1) AS completion_pct
FROM learners
GROUP BY 1;

-- name: q5_progress
-- Laura's Q3: how far did people get? Share of graded assessments submitted.
SELECT CASE
         WHEN assessments_available IS NULL OR assessments_available = 0 THEN '9. No graded assessments in course'
         WHEN assessments_submitted = 0 THEN '0. Submitted none'
         WHEN 1.0 * assessments_submitted / assessments_available < 0.5 THEN '1. Under half'
         WHEN 1.0 * assessments_submitted / assessments_available < 1.0 THEN '2. Half or more'
         ELSE '3. All of them'
       END AS progress,
       COUNT(*)                         AS learners,
       ROUND(100.0 * AVG(completed), 1) AS completion_pct,
       ROUND(100.0 * AVG(withdrew), 1)  AS withdrawal_pct
FROM learners
GROUP BY 1
ORDER BY 1;

-- name: q6_weekly_active_by_outcome
-- The drop-off curve: of each outcome group, what % were active in each week?
SELECT l.final_result,
       w.week,
       COUNT(DISTINCT w.id_student || '-' || w.code_module || '-' || w.code_presentation) AS active_learners,
       ROUND(100.0 * COUNT(DISTINCT w.id_student || '-' || w.code_module || '-' || w.code_presentation)
             / (SELECT COUNT(*) FROM learners x WHERE x.final_result = l.final_result), 1) AS pct_of_group_active
FROM vle_weekly w
JOIN learners l USING (code_module, code_presentation, id_student)
WHERE w.week BETWEEN -3 AND 38
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: q7_segments
-- Who struggles? Outcome rates by learner characteristics (adult/online learner segments).
SELECT 'Age band' AS dimension, age_band AS segment, COUNT(*) AS learners,
       ROUND(100.0 * AVG(withdrew), 1) AS withdrawal_pct, ROUND(100.0 * AVG(completed), 1) AS completion_pct
FROM learners GROUP BY 2
UNION ALL
SELECT 'Prior education', highest_education, COUNT(*),
       ROUND(100.0 * AVG(withdrew), 1), ROUND(100.0 * AVG(completed), 1)
FROM learners GROUP BY 2
UNION ALL
SELECT 'Credits this term',
       CASE WHEN studied_credits <= 60 THEN '60 or fewer' WHEN studied_credits <= 120 THEN '61-120' ELSE 'Over 120' END,
       COUNT(*), ROUND(100.0 * AVG(withdrew), 1), ROUND(100.0 * AVG(completed), 1)
FROM learners GROUP BY 2
UNION ALL
SELECT 'Previous attempts', CASE WHEN num_of_prev_attempts = 0 THEN 'First attempt' ELSE 'Retaking' END,
       COUNT(*), ROUND(100.0 * AVG(withdrew), 1), ROUND(100.0 * AVG(completed), 1)
FROM learners GROUP BY 2
UNION ALL
SELECT 'Deprivation band (IMD)', imd_band, COUNT(*),
       ROUND(100.0 * AVG(withdrew), 1), ROUND(100.0 * AVG(completed), 1)
FROM learners GROUP BY 2;

-- name: q8_never_started
-- "Bought but never showed up": enrolled, never clicked anything.
SELECT COUNT(*) AS enrolled,
       SUM(total_clicks = 0) AS never_clicked,
       ROUND(100.0 * SUM(total_clicks = 0) / COUNT(*), 1) AS pct_never_clicked,
       ROUND(100.0 * AVG(CASE WHEN total_clicks = 0 THEN withdrew END), 1) AS withdrawal_pct_if_never_clicked
FROM learners;
