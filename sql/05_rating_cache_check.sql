-- Proves the denormalised rating totals on drivers equal the reviews they summarise,
-- after seeding and after ratings are changed and reviews soft-deleted. Rolled back.
\pset pager off
CREATE TEMP VIEW rating_mismatches AS
SELECT d.id FROM drivers d
LEFT JOIN LATERAL (SELECT coalesce(sum(r.rating), 0)::int AS s, count(*)::int AS c
                   FROM reviews r JOIN trips t ON t.id = r.trip_id
                   WHERE t.driver_id = d.id AND r.author = 'rider' AND r.deleted_at IS NULL) x ON true
WHERE d.rating_sum <> x.s OR d.rating_count <> x.c;
\echo 'After seeding: drivers whose cached totals differ from their reviews'
SELECT count(*) AS mismatches, (SELECT count(*) FROM drivers) AS drivers, (SELECT sum(rating_count) FROM drivers) AS cached_reviews FROM rating_mismatches;
BEGIN;
UPDATE reviews SET rating = 1 WHERE id IN (SELECT id FROM reviews WHERE author = 'rider' ORDER BY id LIMIT 50);
UPDATE reviews SET deleted_at = now() WHERE id IN (SELECT id FROM reviews WHERE author = 'rider' ORDER BY id DESC LIMIT 50);
\echo 'After changing 50 ratings and soft-deleting 50 reviews'
SELECT count(*) AS mismatches, (SELECT count(*) FROM drivers) AS drivers, (SELECT sum(rating_count) FROM drivers) AS cached_reviews FROM rating_mismatches;
ROLLBACK;
