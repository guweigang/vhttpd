module runtime_plan

// PlanOptions keeps normalized kind-specific values typed without retaining TOML nodes.
pub struct PlanOptions {
pub:
	strings      map[string]string
	ints         map[string]int
	bools        map[string]bool
	string_lists map[string][]string
	string_maps  map[string]map[string]string
	record_lists map[string][]map[string]string
}

pub struct RuntimePlan {
pub:
	version       int = 2
	source        PlanSource
	server        ServerPlan
	listeners     map[string]ListenerPlan
	control       ControlPlan
	observability ObservabilityPlan
	resources     map[string]ResourcePlan
	engines       map[string]EnginePlan
	adapters      map[string]AdapterPlan
	transforms    map[string]TransformPlan
	policies      map[string]PolicyPlan
	pipelines     []PipelinePlan
	relays        map[string]RelayPlan
	diagnostics   []PlanDiagnostic
}

pub struct PlanDiagnostic {
pub:
	severity string
	code     string
	path     string
	message  string
}

pub struct PlanSource {
pub:
	schema_version int
	config_path    string
	compatibility  bool
}

pub struct ServerPlan {
pub:
	timezone            string = 'Asia/Shanghai'
	pid_file            string
	shutdown_timeout_ms int
}

pub struct ListenerPlan {
pub:
	id        string
	protocol  string
	transport string
	host      string
	port      int
	tls       TlsPlan
}

pub struct TlsPlan {
pub:
	enabled      bool
	cert         string
	cert_key     string
	certificates []TlsCertificatePlan
}

pub struct TlsCertificatePlan {
pub:
	hosts    []string
	cert     string
	cert_key string
}

pub struct ControlPlan {
pub:
	listener        ?ResourceRef
	token           string
	internal_socket string
}

pub struct ObservabilityPlan {
pub:
	event_log string
	log_level string
	tracing   TracingPlan
	options   PlanOptions
}

pub struct TracingPlan {
pub:
	enabled     bool
	exporter    string
	endpoint    string
	sample_rate f64
}

pub struct ResourcePlan {
pub:
	id       string
	category string
	kind     string
	options  PlanOptions
}

pub struct EnginePlan {
pub:
	id           string
	kind         string
	resources    []ResourceRef
	capabilities []string
	options      PlanOptions
}

pub struct AdapterPlan {
pub:
	id      string
	kind    string
	engine  ?ResourceRef
	storage ?ResourceRef
	options PlanOptions
}

pub struct TransformPlan {
pub:
	id      string
	kind    string
	engine  ?ResourceRef
	handler string
	options PlanOptions
}

pub struct PolicyPlan {
pub:
	id       string
	category string
	kind     string
	options  PlanOptions
}

pub struct PipelinePlan {
pub:
	id         string
	group      string
	ingress    ResourceRef
	match      MatchPlan
	transforms []ResourceRef
	policies   []ResourceRef
	egress     ResourceRef
}

pub struct MatchPlan {
pub:
	methods     []string
	hosts       []string
	paths       []string
	path_regexp string
	query       map[string]string
	headers     map[string]string
	metadata    map[string]string
}

pub struct RelayPlan {
pub:
	id      string
	mode    string
	carrier string
	ingress ?ResourceRef
	auth    ?ResourceRef
	options PlanOptions
}

pub fn (plan RuntimePlan) pipeline(id string) ?PipelinePlan {
	for pipeline in plan.pipelines {
		if pipeline.id == id {
			return pipeline
		}
	}
	return none
}
