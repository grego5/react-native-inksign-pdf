-- Unified Perfetto report for the Android InkSign diagnostics contract.
--
-- Track-name mappings are intentionally explicit. Keep these names in sync with
-- InkPerfetto.kt and LowLatencyInkHandoff.kt.
-- Target process: com.margelo.nitro.inksignpdf.example
-- Slices: InkSign/<event>, InkSign/C++ <operation>, InkSign/JNI <operation>
-- Counters: InkSign <counter name>

CREATE VIEW report_target_process AS
SELECT upid, pid, name
FROM process
WHERE name = 'com.margelo.nitro.inksignpdf.example'
LIMIT 1;

CREATE VIEW report_target_threads AS
SELECT t.utid, t.tid, t.name, t.upid
FROM thread AS t
JOIN report_target_process AS p ON p.upid = t.upid;

CREATE VIEW report_trace_bounds AS
SELECT start_ts, end_ts, end_ts - start_ts AS duration_ns
FROM trace_bounds;

CREATE VIEW report_latest_counter_rows AS
SELECT ct.id AS track_id,
       ct.name,
       c.ts,
       c.value,
       ROW_NUMBER() OVER (PARTITION BY ct.id ORDER BY c.ts DESC) AS latest_rank
FROM counter_track AS ct
JOIN counter AS c ON c.track_id = ct.id
WHERE ct.name LIKE 'InkSign%';

CREATE VIEW report_latest_counters AS
SELECT name, MAX(value) AS value
FROM report_latest_counter_rows
WHERE latest_rank = 1
GROUP BY name;

CREATE VIEW report_inksign_slices AS
SELECT id, ts, dur, name, track_id, arg_set_id
FROM slice
WHERE name LIKE 'InkSign/%';

CREATE VIEW report_real_mutations AS
SELECT ts, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/JNI real batch mutate+frame';

CREATE VIEW report_prediction_mutations AS
SELECT ts, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/JNI replace prediction';

CREATE VIEW report_cpp_geometry_timings AS
SELECT c.ts, c.value AS duration_ns
FROM counter_track AS ct
JOIN counter AS c ON c.track_id = ct.id
WHERE ct.name = 'InkSign C++ real geometry duration ns'
  AND c.value >= 0;

CREATE VIEW report_app_frames AS
SELECT f.*
FROM actual_frame_timeline_slice AS f
LEFT JOIN report_target_process AS p ON p.upid = f.upid
WHERE f.upid = p.upid
   OR f.layer_name LIKE '%com.margelo.nitro.inksignpdf.example%';

CREATE VIEW report_app_cpu AS
SELECT t.tid,
       t.name,
       SUM(s.dur) AS cpu_ns
FROM report_target_threads AS t
JOIN sched_slice AS s ON s.utid = t.utid
GROUP BY t.tid, t.name;

-- Allocation profiling is optional. The intrinsic heap-profile table exists in
-- trace processor even when no heapprofd data source was captured; an empty
-- result therefore remains distinguishable from a measured zero below.
CREATE VIEW report_heap_allocations AS
SELECT h.ts,
       h.upid,
       h.heap_name,
       h.count AS allocation_count,
       h.size AS allocated_bytes
FROM __intrinsic_heap_profile_allocation AS h
JOIN report_target_process AS p ON p.upid = h.upid
WHERE h.count >= 0
  AND h.size >= 0;

-- ART GC events are emitted as slices by the dalvik atrace category. Keep the
-- mapping scoped to the target process so system-server and renderer GC work
-- does not contaminate the application comparison.
CREATE VIEW report_gc_slices AS
SELECT s.ts,
       s.dur AS duration_ns,
       s.name
FROM slice AS s
JOIN thread_track AS tt ON tt.id = s.track_id
JOIN report_target_threads AS t ON t.utid = tt.utid
WHERE s.dur >= 0
  AND lower(s.name) LIKE '%gc%';

CREATE VIEW report_gc_ranked AS
SELECT duration_ns,
       ROW_NUMBER() OVER (ORDER BY duration_ns) AS rank_in_gc,
       COUNT(*) OVER () AS gc_count
FROM report_gc_slices;

-- Hot-path sources are deliberately kept separate so the report does not
-- confuse JNI wrapper time, C++ geometry time, decode time, or front-buffer
-- callback work. Values in this view are all nanoseconds.
CREATE VIEW report_hot_samples AS
SELECT 'geometry' AS path, duration_ns
FROM report_cpp_geometry_timings
UNION ALL
SELECT 'brush_tip_generation' AS path, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/C++ brush-tip generation'
UNION ALL
SELECT 'upstream_extrusion' AS path, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/C++ upstream extrusion/simplification'
UNION ALL
SELECT 'contour_publication' AS path, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/C++ contour publication'
UNION ALL
SELECT 'decode' AS path, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/frame decode'
UNION ALL
SELECT 'rendering' AS path, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/front-buffer callback drawing'
UNION ALL
SELECT 'input_dispatch' AS path, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/MotionEvent'
UNION ALL
SELECT 'front_buffer_update' AS path, dur AS duration_ns
FROM report_inksign_slices
WHERE name = 'InkSign/dirty region update request'
UNION ALL
SELECT 'prediction_replacement' AS path, duration_ns
FROM report_prediction_mutations;

CREATE VIEW report_hot_ranked AS
SELECT path,
       duration_ns,
       ROW_NUMBER() OVER (PARTITION BY path ORDER BY duration_ns) AS rank_in_path,
       COUNT(*) OVER (PARTITION BY path) AS path_count
FROM report_hot_samples
WHERE duration_ns >= 0;

CREATE VIEW report_native_ranked AS
SELECT 'real_mutation' AS operation, duration_ns
FROM report_real_mutations
UNION ALL
SELECT 'prediction_replacement' AS operation, duration_ns
FROM report_prediction_mutations
UNION ALL
SELECT 'cpp_geometry' AS operation, duration_ns
FROM report_cpp_geometry_timings;

CREATE VIEW report_native_ranked_with_position AS
SELECT operation,
       duration_ns,
       ROW_NUMBER() OVER (PARTITION BY operation ORDER BY duration_ns) AS rank_in_operation,
       COUNT(*) OVER (PARTITION BY operation) AS operation_count
FROM report_native_ranked;

CREATE VIEW report_metric_rows AS
-- trace
SELECT 'trace' AS section, 'duration' AS metric, 'trace' AS scope,
       CAST(duration_ns / 1e9 AS TEXT) AS value, 's' AS unit
FROM report_trace_bounds
UNION ALL
SELECT 'trace', 'captured_bytes', 'trace_file', NULL, 'bytes'
WHERE NOT EXISTS (SELECT 1 FROM metadata WHERE name = 'trace_size_bytes')
UNION ALL
SELECT 'trace', 'captured_bytes', 'trace_file',
       CAST(int_value AS TEXT), 'bytes'
FROM metadata
WHERE name = 'trace_size_bytes'
UNION ALL
SELECT 'trace', 'first_timestamp', 'trace', CAST(start_ts AS TEXT), 'ns'
FROM report_trace_bounds
UNION ALL
SELECT 'trace', 'last_timestamp', 'trace', CAST(end_ts AS TEXT), 'ns'
FROM report_trace_bounds

-- prediction
UNION ALL
SELECT 'prediction', 'requests', 'platform',
       CAST(COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign prediction requests'), 0) AS TEXT), 'count'
UNION ALL
SELECT 'prediction', 'request_rate', 'platform',
       CAST(COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign prediction requests'), 0)
            / NULLIF((SELECT duration_ns FROM report_trace_bounds) / 1e9, 0) AS TEXT), 'per_s'
UNION ALL
SELECT 'prediction', 'suppressed_candidates', 'platform',
       CAST(COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign prediction suppressed'), 0) AS TEXT), 'count'
UNION ALL
SELECT 'prediction', 'suppressed_percentage', 'platform',
       CAST(100.0 * COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign prediction suppressed'), 0)
            / NULLIF((SELECT value FROM report_latest_counters WHERE name = 'InkSign prediction requests'), 0) AS TEXT), '%'
UNION ALL
SELECT 'prediction', 'jni_replacements', 'native', CAST(COUNT(*) AS TEXT), 'count'
FROM report_prediction_mutations
UNION ALL
SELECT 'prediction', 'jni_replacement_rate', 'native',
       CAST(COUNT(*) / NULLIF((SELECT duration_ns FROM report_trace_bounds) / 1e9, 0) AS TEXT), 'per_s'
FROM report_prediction_mutations
UNION ALL
SELECT 'prediction', 'installed_frames', 'platform',
       CAST(COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign prediction frames'), 0) AS TEXT), 'count'
UNION ALL
SELECT 'prediction', 'invalid_or_empty_candidates', 'platform',
       CAST(COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign prediction suppressed'), 0) AS TEXT), 'count'
UNION ALL
SELECT 'prediction', 'final_retained_contours', 'native',
       CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign retained rolling predicted contours') AS TEXT), 'count'
UNION ALL
SELECT 'prediction', 'final_prediction_state', 'front_buffer',
       CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer callback has prediction') AS TEXT), 'bool'

-- native_timing
UNION ALL
SELECT 'native_timing', 'count', operation,
       CAST(operation_count AS TEXT), 'count'
FROM report_native_ranked_with_position
GROUP BY operation
UNION ALL
SELECT 'native_timing', 'rate', operation,
       CAST(operation_count / NULLIF((SELECT duration_ns FROM report_trace_bounds) / 1e9, 0) AS TEXT), 'per_s'
FROM report_native_ranked_with_position
GROUP BY operation
UNION ALL
SELECT 'native_timing', 'average', operation,
       CAST(AVG(duration_ns) / 1e6 AS TEXT), 'ms'
FROM report_native_ranked_with_position
GROUP BY operation
UNION ALL
SELECT 'native_timing', 'p50', operation,
       CAST(MIN(duration_ns) FILTER (WHERE rank_in_operation >= CAST(CEIL(operation_count * 0.50) AS INT)) / 1e6 AS TEXT), 'ms'
FROM report_native_ranked_with_position
GROUP BY operation
UNION ALL
SELECT 'native_timing', 'p95', operation,
       CAST(MIN(duration_ns) FILTER (WHERE rank_in_operation >= CAST(CEIL(operation_count * 0.95) AS INT)) / 1e6 AS TEXT), 'ms'
FROM report_native_ranked_with_position
GROUP BY operation
UNION ALL
SELECT 'native_timing', 'maximum', operation,
       CAST(MAX(duration_ns) / 1e6 AS TEXT), 'ms'
FROM report_native_ranked_with_position
GROUP BY operation
UNION ALL
SELECT 'native_timing', 'emitted_upstream_states', 'geometry',
       CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign C++ emitted upstream states') AS TEXT), 'count'
UNION ALL
SELECT 'native_timing', 'contour_count', 'geometry',
       CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign C++ contour count') AS TEXT), 'count'
UNION ALL
SELECT 'native_timing', 'segment_count', 'geometry',
       CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign C++ segment count') AS TEXT), 'count'
UNION ALL
SELECT 'native_timing', 'serialized_frame_bytes', 'frame',
       CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign C++ serialized frame bytes') AS TEXT), 'bytes'

-- front_buffer
UNION ALL
SELECT 'front_buffer', 'accepted_requests', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer accepted requests') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'callbacks', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer callback received') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'rendered_regions', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer rendered regions') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'published_payloads', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer published payloads') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'resolved_payloads', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer resolved payloads') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'missing_payloads', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer missing payloads') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'rejected_payloads', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer rejected requests') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'superseded_payloads', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer superseded payloads') AS TEXT), 'count'
UNION ALL
SELECT 'front_buffer', 'final_presenter_state', 'presenter', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer presenter state') AS TEXT), 'state'
UNION ALL
SELECT 'front_buffer', 'final_surface_state', 'surface', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer surface valid') AS TEXT), 'bool'
UNION ALL
SELECT 'front_buffer', 'final_renderer_state', 'renderer', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer renderer valid') AS TEXT), 'bool'

-- lifecycle
UNION ALL
SELECT 'lifecycle', 'full_resets', 'front_buffer', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer full resets') AS TEXT), 'count'
UNION ALL
SELECT 'lifecycle', 'handoffs', 'front_buffer', CAST(COUNT(*) AS TEXT), 'count'
FROM report_inksign_slices WHERE name = 'InkSign/real committed'
UNION ALL
SELECT 'lifecycle', 'surface_create', 'surface', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer surface create count') AS TEXT), 'count'
UNION ALL
SELECT 'lifecycle', 'surface_destroy', 'surface', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer surface destroy count') AS TEXT), 'count'
UNION ALL
SELECT 'lifecycle', 'renderer_create', 'renderer', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer renderer create successes') AS TEXT), 'count'
UNION ALL
SELECT 'lifecycle', 'renderer_release', 'renderer', CAST((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer renderer release completions') AS TEXT), 'count'
UNION ALL
SELECT 'lifecycle', 'attachment_changes', 'view', CAST(
  COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer overlay attach count'), 0) +
  COALESCE((SELECT value FROM report_latest_counters WHERE name = 'InkSign front-buffer overlay detach count'), 0)
  AS TEXT), 'count'

-- frames
UNION ALL
SELECT 'frames', 'total_app_frames', 'FrameTimeline', CAST(COUNT(*) AS TEXT), 'count'
FROM report_app_frames
UNION ALL
SELECT 'frames', 'app_frame_rate', 'FrameTimeline',
       CAST(COUNT(*) / NULLIF((SELECT duration_ns FROM report_trace_bounds) / 1e9, 0) AS TEXT), 'per_s'
FROM report_app_frames
UNION ALL
SELECT 'frames', 'janky_frames', 'FrameTimeline', CAST(COUNT(*) AS TEXT), 'count'
FROM report_app_frames
WHERE COALESCE(jank_type, 'None') != 'None'
   OR COALESCE(present_type, '') != 'On-time Present'
UNION ALL
SELECT 'frames', 'deadline_misses', 'FrameTimeline', CAST(COUNT(*) AS TEXT), 'count'
FROM report_app_frames
WHERE COALESCE(jank_type, '') LIKE '%Deadline Missed%'
UNION ALL
SELECT 'frames', 'dropped_app_frames', 'FrameTimeline', CAST(COUNT(*) AS TEXT), 'count'
FROM report_app_frames
WHERE COALESCE(present_type, '') = 'Dropped Frame'
   OR COALESCE(jank_type, '') LIKE '%Dropped Frame%'
UNION ALL
SELECT 'frames', 'jank_percentage', 'FrameTimeline', CAST(
  100.0 * SUM(CASE WHEN COALESCE(jank_type, 'None') != 'None'
                        OR COALESCE(present_type, '') != 'On-time Present' THEN 1 ELSE 0 END)
  / NULLIF(COUNT(*), 0) AS TEXT), '%'
FROM report_app_frames

-- cpu
UNION ALL
SELECT 'cpu', 'application_cpu_time', 'target_process', CAST(COALESCE(SUM(cpu_ns), 0) / 1e6 AS TEXT), 'ms'
FROM report_app_cpu
UNION ALL
SELECT 'cpu', 'main_thread_cpu_time', 'tid=' || CAST((SELECT pid FROM report_target_process) AS TEXT), CAST(COALESCE((SELECT cpu_ns FROM report_app_cpu WHERE tid = (SELECT pid FROM report_target_process)), 0) / 1e6 AS TEXT), 'ms'
UNION ALL
SELECT 'cpu', 'worker_thread_cpu_time', 'target_process_except_main', CAST(COALESCE(SUM(cpu_ns), 0) / 1e6 AS TEXT), 'ms'
FROM report_app_cpu
WHERE tid != (SELECT pid FROM report_target_process)
UNION ALL
SELECT 'cpu', 'application_cpu_utilization', 'target_process', CAST(
  100.0 * COALESCE(SUM(cpu_ns), 0) / NULLIF((SELECT duration_ns FROM report_trace_bounds), 0) AS TEXT), '%'
FROM report_app_cpu

-- hot_paths
UNION ALL
SELECT 'hot_paths', 'count', path, CAST(path_count AS TEXT), 'count'
FROM report_hot_ranked
GROUP BY path
UNION ALL
SELECT 'hot_paths', 'total', path, CAST(SUM(duration_ns) / 1e6 AS TEXT), 'ms'
FROM report_hot_ranked
GROUP BY path
UNION ALL
SELECT 'hot_paths', 'average', path, CAST(AVG(duration_ns) / 1e6 AS TEXT), 'ms'
FROM report_hot_ranked
GROUP BY path
UNION ALL
SELECT 'hot_paths', 'p95', path,
       CAST(MIN(duration_ns) FILTER (WHERE rank_in_path >= CAST(CEIL(path_count * 0.95) AS INT)) / 1e6 AS TEXT), 'ms'
FROM report_hot_ranked
GROUP BY path
UNION ALL
SELECT 'hot_paths', 'maximum', path, CAST(MAX(duration_ns) / 1e6 AS TEXT), 'ms'
FROM report_hot_ranked
GROUP BY path

-- allocation and garbage collection
UNION ALL
SELECT 'allocation', 'heap_profile_available', 'target_process',
       CAST(CASE WHEN EXISTS (SELECT 1 FROM report_heap_allocations)
                 THEN 1 ELSE 0 END AS TEXT), 'bool'
UNION ALL
SELECT 'allocation', 'heap_profile_samples', 'target_process',
       CAST(COUNT(*) AS TEXT), 'count'
FROM report_heap_allocations
UNION ALL
SELECT 'allocation', 'heap_profile_sample_rate', 'target_process',
       CAST(COUNT(*) / NULLIF((SELECT duration_ns FROM report_trace_bounds) / 1e9, 0) AS TEXT), 'per_s'
FROM report_heap_allocations
UNION ALL
SELECT 'allocation', 'heap_profile_allocations', 'target_process',
       CAST(SUM(allocation_count) AS TEXT), 'count'
FROM report_heap_allocations
UNION ALL
SELECT 'allocation', 'heap_profile_bytes', 'target_process',
       CAST(SUM(allocated_bytes) AS TEXT), 'bytes'
FROM report_heap_allocations
UNION ALL
SELECT 'allocation', 'heap_profile_bytes_rate', 'target_process',
       CAST(SUM(allocated_bytes) / NULLIF((SELECT duration_ns FROM report_trace_bounds) / 1e9, 0) AS TEXT), 'bytes_per_s'
FROM report_heap_allocations
UNION ALL
SELECT 'allocation', 'gc_count', 'target_process',
       CAST(COUNT(*) AS TEXT), 'count'
FROM report_gc_slices
UNION ALL
SELECT 'allocation', 'gc_rate', 'target_process',
       CAST(COUNT(*) / NULLIF((SELECT duration_ns FROM report_trace_bounds) / 1e9, 0) AS TEXT), 'per_s'
FROM report_gc_slices
UNION ALL
SELECT 'allocation', 'gc_pause_total', 'target_process',
       CAST(SUM(duration_ns) / 1e6 AS TEXT), 'ms'
FROM report_gc_slices
UNION ALL
SELECT 'allocation', 'gc_pause_percentage', 'target_process',
       CAST(100.0 * SUM(duration_ns) / NULLIF((SELECT duration_ns FROM report_trace_bounds), 0) AS TEXT), '%'
FROM report_gc_slices
UNION ALL
SELECT 'allocation', 'gc_pause_p95', 'target_process',
       CAST(MIN(duration_ns) FILTER (
         WHERE rank_in_gc >= CAST(CEIL(gc_count * 0.95) AS INT)
       ) / 1e6 AS TEXT), 'ms'
FROM report_gc_ranked
UNION ALL
SELECT 'allocation', 'gc_pause_max', 'target_process',
       CAST(MAX(duration_ns) / 1e6 AS TEXT), 'ms'
FROM report_gc_slices

-- Diagnostics make missing optional tracks visible without preventing the
-- normalized report from being emitted.
UNION ALL
SELECT 'diagnostics', 'target_process_present', 'process', CAST(CASE WHEN EXISTS (SELECT 1 FROM report_target_process) THEN 1 ELSE 0 END AS TEXT), 'bool'
UNION ALL
SELECT 'diagnostics', 'observed_processes', 'trace',
       COALESCE((SELECT GROUP_CONCAT(name || ' [pid=' || CAST(pid AS TEXT) || ']', '; ')
                 FROM (SELECT DISTINCT name, pid
                       FROM process
                       WHERE name IS NOT NULL
                       ORDER BY name, pid
                       LIMIT 50)), '[none]'), 'list'
UNION ALL
SELECT 'diagnostics', 'target_process_candidates', 'trace',
       COALESCE((SELECT GROUP_CONCAT(name || ' [pid=' || CAST(pid AS TEXT) || ']', '; ')
                 FROM (SELECT DISTINCT name, pid
                       FROM process
                       WHERE name IS NOT NULL
                         AND lower(name) LIKE '%inksign%'
                       ORDER BY name, pid)), '[none]'), 'list'
UNION ALL
SELECT 'diagnostics', 'frame_timeline_present', 'optional_track', CAST(CASE WHEN EXISTS (SELECT 1 FROM actual_frame_timeline_slice) THEN 1 ELSE 0 END AS TEXT), 'bool'
UNION ALL
SELECT 'diagnostics', 'sched_present', 'optional_track', CAST(CASE WHEN EXISTS (SELECT 1 FROM sched_slice) THEN 1 ELSE 0 END AS TEXT), 'bool'
UNION ALL
SELECT 'diagnostics', 'ink_sign_slices_present', 'track_mapping', CAST(CASE WHEN EXISTS (SELECT 1 FROM report_inksign_slices) THEN 1 ELSE 0 END AS TEXT), 'bool'
UNION ALL
SELECT 'diagnostics', 'allocation_profile_present', 'optional_track', CAST(CASE WHEN EXISTS (SELECT 1 FROM report_heap_allocations) THEN 1 ELSE 0 END AS TEXT), 'bool'
UNION ALL
SELECT 'diagnostics', 'gc_slices_present', 'optional_track', CAST(CASE WHEN EXISTS (SELECT 1 FROM report_gc_slices) THEN 1 ELSE 0 END AS TEXT), 'bool';

SELECT section, metric, scope, value, unit
FROM report_metric_rows
ORDER BY section, metric, scope;
