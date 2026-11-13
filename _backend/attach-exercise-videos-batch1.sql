-- Run this in the Supabase SQL Editor to attach demo videos to the first
-- batch of exercises. Safe to run more than once — it just re-sets the
-- same value. Matches are exact, so it only touches these 9 rows.

update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=A1tmBJKKfVs' where name = 'Barbell Row';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=vw5Xmu5CIew' where name = 'Pull-Up';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=0h6a68JdU2U' where name = 'Barbell Bench Press';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=WDIpL0pjun0' where name = 'Push-Up';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=8PMjqgR8Wa8' where name = 'Barbell Back Squat';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=2SHsk9AzdjA' where name = 'Romanian Deadlift';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=BR4tlEE_A98' where name = 'Goblet Squat';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=mwlp75MS6Rg' where name = 'Plank';
update exercise_catalog set video_url = 'https://www.youtube.com/watch?v=sSESeQAir2M' where name = 'Kettlebell Swings';
