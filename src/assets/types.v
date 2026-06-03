module assets

// AssetsState configures static file serving.
pub struct AssetsState {
pub mut:
	enabled        bool
	prefix         string
	root           string
	root_real      string
	cache_control  string
}
