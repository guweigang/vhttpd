module host

import time

pub enum Action {
	preview_component
	install_component
	select_project
	start
	stop
	force_stop
	clear_logs
	show_all_logs
	open_admin
	open_config
	use_shared_relay
	use_relay_database
	takeover_start
	takeover_stop
	takeover_status
	takeover_prepare
	check_config
	preview_rollback
	compare_history
	restore_rollback
	shutdown
}

pub struct Command {
pub:
	component_id string
	component_source Project
	sequence u64
	action   Action
	project  Project
	rollback_id string
	version_id string
	before_id string
	config_source string
	binary   string
	shared_relay SharedRelay
	relay_database RelayDatabaseSelection
	takeover TakeoverSelection
}

pub struct Worker {
pub:
	commands  chan Command  = chan Command{cap: 8}
	snapshots chan Snapshot = chan Snapshot{cap: 1}
	done      chan bool     = chan bool{cap: 1}
}

pub fn new_worker() Worker {
	w := Worker{}
	spawn supervise(w)
	return w
}

fn supervise(w Worker) {
	mut manager := new_persistent_manager()
	mut notice := ''
	mut sequence := u64(0)
	mut component_result := OperationResult{}
	for {
		select {
			command := <-w.commands {
				sequence = command.sequence
				match command.action {
                    .preview_component, .install_component {
                        notice = ''
                        if command.action == .preview_component {
                            manager.preview_component(command.component_source, command.component_id) or { notice = err.msg() }
                        } else {
                            manager.install_component(command.version_id, command.binary) or { notice = err.msg() }
                        }
                        component_result = OperationResult{sequence:command.sequence, action:if command.action == .preview_component {'preview'} else {'install'}, target:manager.project.config_path, preview_id:manager.component_preview.id, error:notice != '', message:if notice != '' {notice} else {manager.message}}
                    }
					.select_project {
						notice = ''
						manager.select_project(command.project) or { notice = err.msg() }
					}
					.start {
						notice = ''
						manager.start(command.project, command.binary) or { notice = err.msg() }
					}
					.open_config {
						notice = ''
						manager.open_config(command.config_source) or { notice = err.msg() }
					}
					.use_shared_relay {
						notice = ''
						manager.use_shared_relay(command.shared_relay) or { notice = err.msg() }
					}
					.use_relay_database {
						notice = ''
						manager.use_relay_database(command.shared_relay, command.relay_database) or { notice = err.msg() }
					}
                    .takeover_start, .takeover_stop, .takeover_status {
                        notice = ''
                        action := if command.action == .takeover_start {'start'} else if command.action == .takeover_stop {'stop'} else {'status'}
                        manager.control_takeover(action,command.takeover) or {notice=err.msg()}
                    }
                    .takeover_prepare {
                        notice = ''
                        manager.prepare_takeover_receiver(command.takeover) or {notice=err.msg()}
                    }
					.preview_rollback {
						notice = ''
						if command.version_id == '' { manager.preview_config_rollback() or { notice = err.msg() } } else { manager.preview_history_rollback(command.version_id) or { notice = err.msg() } }
					}
					.compare_history {
						notice = ''
						manager.compare_history_versions(command.before_id, command.version_id) or { notice = err.msg() }
					}
					.restore_rollback {
						notice = ''
						manager.restore_config_rollback(command.rollback_id) or { notice = err.msg() }
					}
					.check_config { manager.refresh_config_status() }
					.stop { manager.stop() }
					.force_stop { manager.force_stop() }
					.clear_logs { manager.clear_logs() }
					.show_all_logs { manager.log_filter = '' }
					.open_admin {
						notice = ''
						if manager.snapshot().phase == .running {
							manager.open_admin() or { notice = err.msg() }
						}
					}
					.shutdown {
						manager.shutdown()
						w.done <- true
						return
					}
				}
			}
			else {
			}
		}
		manager.tick()
		s := manager.snapshot()
		message := if notice != '' { notice } else { s.message }
		snapshot := Snapshot{ ...s, sequence: sequence, message: message, component_result:component_result }
		select {
			w.snapshots <- snapshot {
			}
			else {
			}
		}
		time.sleep(70 * time.millisecond)
	}
}
