# Dashboard

Built in Tableau Public from `outputs/learners_for_dashboard.csv` (one row per learner per course run).

**Live dashboard:** _add your Tableau Public link here_

![Dashboard screenshot](dashboard.png)
_Add a screenshot named `dashboard.png` to this folder._

## Page 1 - The learner journey
- KPI tiles: enrollments, completion rate, withdrawal rate, % who never logged in
- When learners withdraw (`q3_withdrawal_timing`, `q3b_withdrawal_by_week`)
- Weekly active % by outcome - the drop-off curve (`q6_weekly_active_by_outcome`)
- Filter: course (`code_module`)

## Page 2 - What predicts finishing
- First-month activity vs. outcome (`q4_first_month_engagement`)
- Registration timing vs. outcome (`q2_registration_timing`)
- Segments: age band, credit load, prior education (`q7_segments`)
