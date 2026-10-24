module admin

fn test_browser_ticket_single_use_and_session_lifecycle() {
	mut auth := BrowserAuth{}
	ticket := auth.issue_ticket(100)!
	assert ticket.len == 64
	assert !auth.authorized(ticket, 100)
	session := auth.exchange(ticket, 101)!
	assert session != ticket
	assert auth.authorized(session, 102)
	auth.exchange(ticket, 102) or {
		assert err.msg().contains('already used')
		auth.revoke(session)
		assert !auth.authorized(session, 103)
		return
	}
	assert false, 'Ticket was accepted twice'
}

fn test_browser_expiry_restart_and_limits() {
	mut auth := BrowserAuth{}
	ticket := auth.issue_ticket(100)!
	auth.exchange(ticket, 130) or {
		fresh := auth.issue_ticket(131)!
		session := auth.exchange(fresh, 132)!
		assert !auth.authorized(session, 132 + browser_session_seconds)
		mut restarted := BrowserAuth{}
		assert !restarted.authorized(session, 133)
		for _ in 0 .. 32 { auth.issue_ticket(200)! }
		auth.issue_ticket(201) or {
			assert err.msg().contains('Too many')
			assert auth.issue_ticket(230)!.len == 64
			return
		}
	}
	assert false, 'Expired ticket or unbounded issuance accepted'
}

fn test_browser_csrf_enforces_origin_and_port() {
	origin := 'http://127.0.0.1:20100'
	assert browser_request_allowed('GET', '127.0.0.1:20100', '', 'same-origin', origin)
	assert browser_request_allowed('POST', '127.0.0.1:20100', origin, 'same-origin', origin)
	assert !browser_request_allowed('POST', '127.0.0.1:20100', '', '', origin)
	assert !browser_request_allowed('POST', '127.0.0.1:20100', 'null', '', origin)
	assert !browser_request_allowed('POST', '127.0.0.1:20100', 'http://127.0.0.1:3000', 'same-site', origin)
	assert !browser_request_allowed('GET', '127.0.0.1:20100', '', 'cross-site', origin)
	assert !browser_request_allowed('GET', 'attacker.test:20100', '', '', origin)
}
