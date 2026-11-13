module main

import json2 as json

const development_skill = $embed_file('development_guidance/vhttpd-workbench/references/develop.md')
const development_vjsx_reference = $embed_file('development_guidance/contracts/vjsx.md')

fn packaged_development_guide(topic string) !string {
	content := match topic {
		'develop' { development_skill.to_string() }
		'vjsx' { development_vjsx_reference.to_string() }
		else { return error('unknown_guidance_topic') }
	}
	return json.encode({
		'topic':           topic
		'content':         content
		'source':          'runtime_package'
		'runtime_version': vhttpd_version
		'profile':         'script'
	})
}
