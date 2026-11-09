module relaydb

fn test_probe_requires_expected_mysql_constant_result_and_masks_driver_errors() {
	assert probe_response('{"ok":true,"driver":"mysql","rows":[{"relay_probe":"1"}]}').ok
	for raw in ['not json', '{"ok":true,"driver":"pgsql","rows":[{"relay_probe":"1"}]}', '{"ok":true,"driver":"mysql","rows":[{"relay_probe":"2"}]}', '{"ok":false,"error":"password=private-fixture SQL secret"}'] {
		result := probe_response(raw)
		assert !result.ok
		assert !result.error.contains('secret') && !result.error.contains('private-fixture')
	}
}
