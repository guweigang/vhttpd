module executor

import json2 as json

struct InProcVjsxSnapshotJson {}

fn InProcVjsxSnapshotJson.json_or_null(raw string) string {
	trimmed := raw.trim_space()
	if trimmed == '' || trimmed == 'undefined' {
		return 'null'
	}
	return trimmed
}

fn InProcVjsxSnapshotJson.item(lane_id string, available bool, snapshot_raw string, err_msg string) string {
	return '{"laneId":${json.encode(lane_id, escape_unicode: true, time_as_unix: true)},"available":${if available {
		'true'
	} else {
		'false'
	}},"snapshot":${InProcVjsxSnapshotJson.json_or_null(snapshot_raw)},"error":${json.encode(err_msg, escape_unicode: true, time_as_unix: true)}}'
}

fn InProcVjsxSnapshotJson.aggregate(scope string, kind string, current_lane_id string, item_jsons []string) string {
	return '{"scope":${json.encode(scope, escape_unicode: true, time_as_unix: true)},"kind":${json.encode(kind, escape_unicode: true, time_as_unix: true)},"currentLaneId":${json.encode(current_lane_id, escape_unicode: true, time_as_unix: true)},"lanes":[${item_jsons.join(',')}]}'
}
