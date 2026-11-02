SELECT
    id, 
    ST_AsText(location) AS coordinates,
    ROUND(ST_Distance(location, ST_SetSRID(ST_MakePoint(139.7454, 35.6586), 4326))::numeric, 2) AS distance_meters
FROM
    track_points
WHERE
    ST_DWithin(location, ST_SetSRID(ST_MakePoint(139.7454, 35.6586), 4326), 1000)
ORDER BY
    distance_meters ASC;
