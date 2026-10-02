-- Optional extension: the "landing page to checkout" half of the journey.
-- Runs in Google BigQuery (free sandbox) on Google's public GA4 sample ecommerce data
-- (Google Merchandise Store, Nov 1 2020 - Jan 31 2021). The data is deliberately
-- obfuscated by Google, so treat results as illustrative, not real store performance.

-- 1. Funnel: how many users reach each step?
SELECT event_name,
       COUNT(DISTINCT user_pseudo_id) AS users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name IN ('session_start', 'view_item', 'add_to_cart',
                     'begin_checkout', 'add_payment_info', 'purchase')
GROUP BY event_name
ORDER BY users DESC;

-- 2. Time from first visit to first purchase, for users who bought.
WITH firsts AS (
  SELECT user_pseudo_id,
         MIN(IF(event_name = 'first_visit', event_timestamp, NULL)) AS first_visit_ts,
         MIN(IF(event_name = 'purchase',    event_timestamp, NULL)) AS first_purchase_ts
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT COUNT(*) AS purchasers,
       APPROX_QUANTILES(
         TIMESTAMP_DIFF(TIMESTAMP_MICROS(first_purchase_ts),
                        TIMESTAMP_MICROS(first_visit_ts), HOUR), 4) AS hours_to_purchase_quartiles
FROM firsts
WHERE first_visit_ts IS NOT NULL
  AND first_purchase_ts IS NOT NULL
  AND first_purchase_ts >= first_visit_ts;
