-- 0. reflesh tables
TRUNCATE TABLE users CASCADE;

-- 1. dummy data for users table
-- パスワード等の認証の情報は、この後に`python -m app.cli seed-dev`で設定する(argon2のハッシュはSQLでは作れないため)
INSERT INTO users (id, email, display_name) VALUES
('11111111-1111-1111-1111-111111111111', 'testuser@example.com', 'テストユーザー')
ON CONFLICT (email) DO NOTHING;

-- 2. dummy data for sessions table
INSERT INTO sessions (
    id, user_id, name, started_at, ended_at, is_favorite, move_method,
    total_distance, duration_seconds, elevation_gain, max_altitude, min_altitude
) VALUES (
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    '11111111-1111-1111-1111-111111111111',
    '朝の散歩',
    '2026-08-19 07:00:00+09', '2026-08-19 07:40:00+09',
    TRUE, 'walk', 3.5, 2400, 25.0, 30.0, 15.0
),
(
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22',
    '11111111-1111-1111-1111-111111111111',
    '夕方ランニング',
    '2026-08-18 18:00:00+09', '2026-08-18 18:50:00+09',
    FALSE, 'run', 8.2, 3000, 60.0, 70.0, 35.0
),
(
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33',
    '11111111-1111-1111-1111-111111111111',
    '休日サイクリング',
    '2026-08-16 10:00:00+09', '2026-08-16 11:15:00+09',
    TRUE, 'bicycle', 18.0, 4500, 120.0, 65.0, 20.0
)
ON CONFLICT (id) DO NOTHING;

-- 3. dummy data for track_points table
-- using ST_SetSRID and ST_MakPoint
INSERT INTO track_points (session_id, location, recorded_at) VALUES
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', ST_SetSRID(ST_MakePoint(139.7671, 35.6812, 22.0), 4326), '2026-08-19 07:00:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', ST_SetSRID(ST_MakePoint(139.7680, 35.6820, 35.0), 4326), '2026-08-19 07:10:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', ST_SetSRID(ST_MakePoint(139.7695, 35.6835, 80.0), 4326), '2026-08-19 07:20:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', ST_SetSRID(ST_MakePoint(139.7710, 35.6850, 165.0), 4326), '2026-08-19 07:30:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', ST_SetSRID(ST_MakePoint(139.7725, 35.6862, 120.0), 4326), '2026-08-19 07:40:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', ST_SetSRID(ST_MakePoint(139.7005, 35.6895, 35.0), 4326), '2026-08-18 18:00:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', ST_SetSRID(ST_MakePoint(139.7020, 35.6910, 95.0), 4326), '2026-08-18 18:15:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', ST_SetSRID(ST_MakePoint(139.7045, 35.6930, 210.0), 4326), '2026-08-18 18:30:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', ST_SetSRID(ST_MakePoint(139.7070, 35.6950, 150.0), 4326), '2026-08-18 18:50:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33', ST_SetSRID(ST_MakePoint(139.6917, 35.6895, 40.0), 4326), '2026-08-16 10:00:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33', ST_SetSRID(ST_MakePoint(139.7100, 35.7000, 280.0), 4326), '2026-08-16 10:35:00+09'),
('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33', ST_SetSRID(ST_MakePoint(139.7300, 35.7100, 110.0), 4326), '2026-08-16 11:15:00+09');