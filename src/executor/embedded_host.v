module executor

// Embedded hosts need application services, without worker socket or transport access.
pub interface EmbeddedHost {
	RuntimeConfigFacade
	PlatformFacade
	ProviderBridgeFacade
	CommandDispatchFacade
	WebSocketCommandFacade
}
