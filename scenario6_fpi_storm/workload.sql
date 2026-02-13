-- Scattered random UPDATE: touches a different page almost every time.
-- After each checkpoint, this generates an 8 KB FPI instead of a ~200 B delta.
\set id random(1, 2000000)
UPDATE wide_table SET counter = counter + 1 WHERE id = :id;
