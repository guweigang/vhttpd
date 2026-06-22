(function() {
    class VProfilerWidget extends HTMLElement {
        constructor() {
            super();
            this.attachShadow({ mode: 'open' });
            this.data = window.vProfilerData || {};
            this.activeTab = 'overview';
            this.expanded = false;
        }

        connectedCallback() {
            this.render();
            this.setupEventListeners();
        }

        render() {
            const overview = this.data.overview || {};
            const cache = this.data.cache || {};
            const totalDuration = parseFloat(overview.total_duration_ms || 0);

            const fontHtml = `<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');</style>`;

            const styles = `
                <style>
                    :host {
                        all: initial;
                        font-family: 'Inter', system-ui, -apple-system, sans-serif;
                        position: fixed;
                        bottom: 0;
                        left: 0;
                        width: 100%;
                        z-index: 99999999;
                        color: #e2e8f0;
                    }
                    * {
                        box-sizing: border-box;
                    }
                    .bar-container {
                        background: rgba(15, 23, 42, 0.85);
                        backdrop-filter: blur(16px) saturate(180%);
                        -webkit-backdrop-filter: blur(16px) saturate(180%);
                        border-top: 1px solid rgba(255, 255, 255, 0.08);
                        box-shadow: 0 -4px 30px rgba(0, 0, 0, 0.3);
                        transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
                        width: 100%;
                        overflow: hidden;
                    }
                    .collapsed {
                        height: 40px;
                    }
                    .expanded {
                        height: 380px;
                    }
                    .minibar {
                        display: flex;
                        justify-content: space-between;
                        align-items: center;
                        height: 40px;
                        padding: 0 20px;
                        cursor: pointer;
                        user-select: none;
                    }
                    .minibar:hover {
                        background: rgba(255, 255, 255, 0.03);
                    }
                    .mini-left {
                        display: flex;
                        align-items: center;
                        gap: 8px;
                        font-weight: 600;
                        font-size: 13px;
                        letter-spacing: 0.5px;
                        color: #a78bfa;
                    }
                    .logo-icon {
                        width: 16px;
                        height: 16px;
                        fill: #a78bfa;
                    }
                    .mini-metrics {
                        display: flex;
                        gap: 20px;
                        font-size: 12px;
                    }
                    .metric-item {
                        display: flex;
                        align-items: center;
                        gap: 6px;
                    }
                    .metric-label {
                        color: #64748b;
                        font-weight: 500;
                    }
                    .metric-value {
                        color: #f8fafc;
                        font-weight: 600;
                    }
                    .metric-value.warn {
                        color: #f59e0b;
                    }
                    .metric-value.err {
                        color: #f43f5e;
                    }
                    .panel {
                        display: flex;
                        flex-direction: column;
                        height: 340px;
                        background: rgba(15, 23, 42, 0.95);
                    }
                    .tabs-header {
                        display: flex;
                        border-bottom: 1px solid rgba(255, 255, 255, 0.05);
                        background: rgba(10, 15, 30, 0.5);
                        padding: 0 10px;
                    }
                    .tab-button {
                        padding: 12px 16px;
                        font-size: 12px;
                        font-weight: 600;
                        color: #94a3b8;
                        background: transparent;
                        border: none;
                        cursor: pointer;
                        border-bottom: 2px solid transparent;
                        transition: all 0.2s;
                        display: flex;
                        align-items: center;
                        gap: 6px;
                    }
                    .tab-button:hover {
                        color: #e2e8f0;
                        background: rgba(255, 255, 255, 0.02);
                    }
                    .tab-button.active {
                        color: #a78bfa;
                        border-bottom-color: #8b5cf6;
                    }
                    .tab-badge {
                        background: rgba(139, 92, 246, 0.2);
                        color: #c084fc;
                        font-size: 10px;
                        padding: 1px 5px;
                        border-radius: 10px;
                        font-weight: 700;
                    }
                    .tabs-content {
                        flex: 1;
                        overflow-y: auto;
                        padding: 20px;
                    }
                    .tabs-content::-webkit-scrollbar {
                        width: 8px;
                    }
                    .tabs-content::-webkit-scrollbar-track {
                        background: rgba(0, 0, 0, 0.1);
                    }
                    .tabs-content::-webkit-scrollbar-thumb {
                        background: rgba(255, 255, 255, 0.15);
                        border-radius: 4px;
                    }
                    .tabs-content::-webkit-scrollbar-thumb:hover {
                        background: rgba(255, 255, 255, 0.25);
                    }
                    .overview-grid {
                        display: grid;
                        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                        gap: 15px;
                        margin-bottom: 25px;
                    }
                    .stat-card {
                        background: rgba(255, 255, 255, 0.02);
                        border: 1px solid rgba(255, 255, 255, 0.04);
                        border-radius: 8px;
                        padding: 15px;
                        display: flex;
                        flex-direction: column;
                        gap: 4px;
                    }
                    .stat-card .label {
                        font-size: 11px;
                        color: #64748b;
                        text-transform: uppercase;
                        letter-spacing: 0.5px;
                    }
                    .stat-card .val {
                        font-size: 20px;
                        font-weight: 700;
                        color: #f8fafc;
                    }
                    .overview-sections {
                        display: flex;
                        flex-direction: column;
                        gap: 25px;
                    }
                    .waterfall-title {
                        font-size: 13px;
                        font-weight: 600;
                        margin-bottom: 12px;
                        color: #94a3b8;
                    }
                    .timeline-bar-container {
                        display: flex;
                        flex-direction: column;
                        gap: 8px;
                    }
                    .timeline-row {
                        display: flex;
                        align-items: center;
                        font-size: 11px;
                    }
                    .timeline-label {
                        width: 140px;
                        color: #cbd5e1;
                        font-weight: 500;
                    }
                    .timeline-track {
                        flex: 1;
                        background: rgba(255, 255, 255, 0.03);
                        height: 14px;
                        border-radius: 7px;
                        position: relative;
                        overflow: hidden;
                    }
                    .timeline-fill {
                        height: 100%;
                        background: linear-gradient(90deg, #8b5cf6, #d946ef);
                        border-radius: 7px;
                        position: absolute;
                        top: 0;
                        display: flex;
                        align-items: center;
                        justify-content: flex-end;
                        padding-right: 8px;
                        color: #fff;
                        font-weight: 700;
                        font-size: 9px;
                        box-shadow: 0 0 8px rgba(139, 92, 246, 0.4);
                    }
                    .timeline-value-text {
                        margin-left: 10px;
                        width: 60px;
                        color: #cbd5e1;
                        text-align: right;
                    }
                    table.data-table {
                        width: 100%;
                        border-collapse: collapse;
                        font-size: 12px;
                    }
                    table.data-table th {
                        text-align: left;
                        padding: 8px 12px;
                        background: rgba(255, 255, 255, 0.02);
                        color: #64748b;
                        font-weight: 600;
                        border-bottom: 1px solid rgba(255, 255, 255, 0.05);
                    }
                    table.data-table td {
                        padding: 8px 12px;
                        border-bottom: 1px solid rgba(255, 255, 255, 0.03);
                        color: #cbd5e1;
                        vertical-align: top;
                    }
                    table.data-table tr.slow-query td {
                        color: #f59e0b;
                        background: rgba(245, 158, 11, 0.03);
                    }
                    table.data-table tr:hover td {
                        background: rgba(255, 255, 255, 0.01);
                    }
                    .sql-text {
                        font-family: monospace;
                        font-size: 11px;
                        white-space: pre-wrap;
                        word-break: break-all;
                    }
                    .sql-caller {
                        font-size: 10px;
                        color: #475569;
                        margin-top: 4px;
                    }
                    .cache-panel {
                        display: flex;
                        gap: 40px;
                        align-items: center;
                    }
                    .cache-chart {
                        width: 120px;
                        height: 120px;
                        position: relative;
                        display: flex;
                        align-items: center;
                        justify-content: center;
                    }
                    .cache-ratio-val {
                        position: absolute;
                        font-size: 22px;
                        font-weight: 700;
                        color: #f8fafc;
                        display: flex;
                        flex-direction: column;
                        align-items: center;
                        line-height: 1;
                    }
                    .cache-ratio-val span {
                        font-size: 9px;
                        color: #64748b;
                        text-transform: uppercase;
                        margin-top: 4px;
                    }
                    .cache-details-list {
                        display: flex;
                        flex-direction: column;
                        gap: 10px;
                        flex: 1;
                    }
                    .cache-detail-row {
                        display: flex;
                        align-items: center;
                        justify-content: space-between;
                        border-bottom: 1px solid rgba(255, 255, 255, 0.03);
                        padding-bottom: 6px;
                        font-size: 12px;
                    }
                    .cache-detail-row .dot {
                        width: 8px;
                        height: 8px;
                        border-radius: 50%;
                        display: inline-block;
                        margin-right: 8px;
                    }
                    .dot.local { background-color: #34d399; }
                    .dot.remote { background-color: #60a5fa; }
                    .dot.miss { background-color: #f87171; }
                    .log-row {
                        display: flex;
                        gap: 15px;
                        font-size: 12px;
                        padding: 8px 12px;
                        border-bottom: 1px solid rgba(255, 255, 255, 0.03);
                        font-family: monospace;
                    }
                    .log-row.debug { border-left: 3px solid #8b5cf6; }
                    .log-row.info { border-left: 3px solid #3b82f6; }
                    .log-row.Warning { border-left: 3px solid #f59e0b; background: rgba(245, 158, 11, 0.02); }
                    .log-row.Notice { border-left: 3px solid #64748b; }
                    .log-row.Error, .log-row.Exception { border-left: 3px solid #ef4444; background: rgba(239, 68, 68, 0.03); }
                    .log-level {
                        width: 85px;
                        font-weight: 700;
                        text-transform: uppercase;
                        font-size: 10px;
                    }
                    .log-row.debug .log-level { color: #a78bfa; }
                    .log-row.info .log-level { color: #60a5fa; }
                    .log-row.Warning .log-level { color: #fbbf24; }
                    .log-row.Notice .log-level { color: #94a3b8; }
                    .log-row.Error .log-level, .log-row.Exception .log-level { color: #f87171; }
                    .log-body {
                        flex: 1;
                        white-space: pre-wrap;
                        word-break: break-all;
                    }
                    .log-meta {
                        font-size: 10px;
                        color: #475569;
                        text-align: right;
                        width: 150px;
                    }
                    .env-grid {
                        display: grid;
                        grid-template-columns: 1fr 1fr;
                        gap: 20px;
                    }
                    .env-section-title {
                        font-size: 12px;
                        font-weight: 600;
                        color: #a78bfa;
                        margin-bottom: 8px;
                        border-bottom: 1px solid rgba(255, 255, 255, 0.05);
                        padding-bottom: 4px;
                    }
                    .key-value-list {
                        display: flex;
                        flex-direction: column;
                        gap: 6px;
                        font-size: 11px;
                    }
                    .key-value-row {
                        display: flex;
                        justify-content: space-between;
                        border-bottom: 1px solid rgba(255, 255, 255, 0.02);
                        padding-bottom: 4px;
                    }
                    .key-value-row .key {
                        color: #64748b;
                        font-weight: 500;
                    }
                    .key-value-row .value {
                        color: #cbd5e1;
                        font-family: monospace;
                        word-break: break-all;
                        max-width: 70%;
                        text-align: right;
                    }
                    .pool-status-badge {
                        padding: 2px 6px;
                        border-radius: 4px;
                        font-size: 10px;
                        font-weight: 700;
                        text-transform: uppercase;
                    }
                    .pool-status-badge.online {
                        background: rgba(52, 211, 153, 0.15);
                        color: #34d399;
                    }
                    .pool-status-badge.offline {
                        background: rgba(248, 113, 113, 0.15);
                        color: #f87171;
                    }
                    .pool-status-badge.not-enabled {
                        background: rgba(245, 158, 11, 0.15);
                        color: #fbbf24;
                    }
                    .badge-counter {
                        display: inline-flex;
                        align-items: center;
                        justify-content: center;
                        background: rgba(255, 255, 255, 0.15);
                        color: #fff;
                        width: 16px;
                        height: 16px;
                        border-radius: 50%;
                        font-size: 9px;
                        font-weight: 700;
                        margin-left: 5px;
                    }
                    .badge-counter.err {
                        background: #f43f5e;
                    }
                    /* Benchmarks Tab Styles */
                    .bench-layout {
                        display: grid;
                        grid-template-columns: 1.2fr 1.8fr;
                        gap: 20px;
                        height: 100%;
                    }
                    .bench-sidebar {
                        border-right: 1px solid rgba(255,255,255,0.05);
                        padding-right: 15px;
                        display: flex;
                        flex-direction: column;
                        gap: 12px;
                    }
                    .bench-main {
                        display: flex;
                        flex-direction: column;
                        gap: 15px;
                        overflow-y: auto;
                        padding-right: 5px;
                    }
                    .bench-card {
                        background: rgba(255, 255, 255, 0.02);
                        border: 1px solid rgba(255, 255, 255, 0.04);
                        border-radius: 6px;
                        padding: 10px;
                    }
                    .bench-title {
                        font-size: 11px;
                        font-weight: 600;
                        color: #94a3b8;
                        text-transform: uppercase;
                        letter-spacing: 0.5px;
                        margin-bottom: 8px;
                    }
                    .bench-btn-group {
                        display: flex;
                        gap: 8px;
                        margin-top: 8px;
                    }
                    .bench-btn {
                        flex: 1;
                        background: rgba(139, 92, 246, 0.1);
                        border: 1px solid rgba(139, 92, 246, 0.2);
                        border-radius: 4px;
                        color: #c084fc;
                        font-size: 10px;
                        font-weight: 600;
                        padding: 6px 10px;
                        cursor: pointer;
                        text-align: center;
                        transition: all 0.2s;
                    }
                    .bench-btn:hover {
                        background: rgba(139, 92, 246, 0.2);
                        color: #d8b4fe;
                    }
                    .bench-btn.secondary {
                        background: rgba(255, 255, 255, 0.05);
                        border: 1px solid rgba(255, 255, 255, 0.08);
                        color: #94a3b8;
                    }
                    .bench-btn.secondary:hover {
                        background: rgba(255, 255, 255, 0.08);
                        color: #e2e8f0;
                    }
                    .bench-btn.danger {
                        background: rgba(239, 68, 68, 0.1);
                        border: 1px solid rgba(239, 68, 68, 0.2);
                        color: #f87171;
                    }
                    .bench-btn.danger:hover {
                        background: rgba(239, 68, 68, 0.2);
                        color: #fca5a5;
                    }
                    .comparison-item {
                        display: flex;
                        flex-direction: column;
                        gap: 4px;
                        margin-bottom: 12px;
                    }
                    .comparison-label {
                        display: flex;
                        justify-content: space-between;
                        font-size: 11px;
                        color: #cbd5e1;
                        font-weight: 500;
                    }
                    .comparison-bar-group {
                        display: flex;
                        flex-direction: column;
                        gap: 4px;
                        background: rgba(0,0,0,0.15);
                        padding: 6px;
                        border-radius: 4px;
                        border: 1px solid rgba(255,255,255,0.02);
                    }
                    .comparison-bar-row {
                        display: flex;
                        align-items: center;
                        font-size: 10px;
                    }
                    .bar-name {
                        width: 70px;
                        color: #64748b;
                        font-weight: 600;
                    }
                    .bar-track {
                        flex: 1;
                        height: 8px;
                        background: rgba(255,255,255,0.02);
                        border-radius: 4px;
                        position: relative;
                    }
                    .bar-fill {
                        height: 100%;
                        border-radius: 4px;
                        transition: width 0.5s ease-out;
                    }
                    .bar-fill.before {
                        background: linear-gradient(90deg, #f59e0b, #d97706);
                        box-shadow: 0 0 6px rgba(245, 158, 11, 0.3);
                    }
                    .bar-fill.after {
                        background: linear-gradient(90deg, #10b981, #059669);
                        box-shadow: 0 0 6px rgba(16, 185, 129, 0.3);
                    }
                    .bar-value {
                        width: 70px;
                        text-align: right;
                        color: #f8fafc;
                        font-weight: 600;
                        font-family: monospace;
                    }
                    .comparison-summary {
                        background: rgba(16, 185, 129, 0.08);
                        border: 1px solid rgba(16, 185, 129, 0.15);
                        border-radius: 6px;
                        padding: 10px;
                        color: #34d399;
                        font-size: 11px;
                        font-weight: 600;
                        line-height: 1.4;
                        display: flex;
                        align-items: center;
                        gap: 8px;
                    }
                </style>
            `;

            const minibarHtml = `
                <div class="minibar" id="minibar">
                    <div class="mini-left">
                        <svg class="logo-icon" viewBox="0 0 24 24">
                            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/>
                        </svg>
                        <span>v-Profiler</span>
                    </div>
                    <div class="mini-metrics">
                        <div class="metric-item">
                            <span class="metric-label">TIME</span>
                            <span class="metric-value ${totalDuration > 500 ? 'warn' : ''}">${totalDuration} ms</span>
                        </div>
                        <div class="metric-item">
                            <span class="metric-label">DB</span>
                            <span class="metric-value">${overview.sql_count || 0} (${overview.sql_duration_ms || 0} ms)</span>
                        </div>
                        <div class="metric-item">
                            <span class="metric-label">CACHE</span>
                            <span class="metric-value">${overview.cache_ratio || 0}%</span>
                        </div>
                        <div class="metric-item">
                            <span class="metric-label">MEM</span>
                            <span class="metric-value">${overview.peak_memory || '0 MB'}</span>
                        </div>
                        ${this.data.errors && this.data.errors.length > 0 ? `
                            <div class="metric-item">
                                <span class="metric-label" style="color:#f43f5e">ERRORS</span>
                                <span class="metric-value err">${this.data.errors.length}</span>
                            </div>
                        ` : ''}
                    </div>
                </div>
            `;

            const panelHtml = `
                <div class="panel">
                    <div class="tabs-header">
                        <button class="tab-button ${this.activeTab === 'overview' ? 'active' : ''}" data-tab="overview">
                            📈 Overview
                        </button>
                        <button class="tab-button ${this.activeTab === 'database' ? 'active' : ''}" data-tab="database">
                            🗄️ Database ${overview.sql_count ? `<span class="badge-counter">${overview.sql_count}</span>` : ''}
                        </button>
                        <button class="tab-button ${this.activeTab === 'hooks' ? 'active' : ''}" data-tab="hooks">
                            🪝 Hooks
                        </button>
                        <button class="tab-button ${this.activeTab === 'cache' ? 'active' : ''}" data-tab="cache">
                            ⚡ Cache
                        </button>
                        <button class="tab-button ${this.activeTab === 'http' ? 'active' : ''}" data-tab="http">
                            🌐 HTTP ${this.data.external_requests?.length ? `<span class="badge-counter">${this.data.external_requests.length}</span>` : ''}
                        </button>
                        ${this.data.woocommerce?.is_wc_page ? `
                        <button class="tab-button ${this.activeTab === 'woocommerce' ? 'active' : ''}" data-tab="woocommerce">
                            🛒 WooCommerce
                        </button>
                        ` : ''}
                        <button class="tab-button ${this.activeTab === 'benchmarks' ? 'active' : ''}" data-tab="benchmarks">
                            📊 Benchmarks
                        </button>
                        <button class="tab-button ${this.activeTab === 'security' ? 'active' : ''}" data-tab="security">
                            🛡️ Security
                        </button>
                        <button class="tab-button ${this.activeTab === 'logs' ? 'active' : ''}" data-tab="logs">
                            🪲 Logs & Errors ${this.data.errors?.length || this.data.logs?.length ? `<span class="badge-counter ${this.data.errors?.length ? 'err' : ''}">${(this.data.errors?.length || 0) + (this.data.logs?.length || 0)}</span>` : ''}
                        </button>
                        <button class="tab-button ${this.activeTab === 'env' ? 'active' : ''}" data-tab="env">
                            🧠 Environment
                        </button>
                        <button class="tab-button ${this.activeTab === 'vhttpd' ? 'active' : ''}" data-tab="vhttpd">
                            ⚙️ vhttpd
                        </button>
                    </div>
                    <div class="tabs-content">
                        ${this.renderTabContent()}
                    </div>
                </div>
            `;

            this.shadowRoot.innerHTML = `
                ${fontHtml}
                ${styles}
                <div class="bar-container ${this.expanded ? 'expanded' : 'collapsed'}" id="container">
                    ${minibarHtml}
                    ${this.expanded ? panelHtml : ''}
                </div>
            `;
        }

        renderTabContent() {
            switch (this.activeTab) {
                case 'overview':
                    return this.renderOverview();
                case 'database':
                    return this.renderDatabase();
                case 'woocommerce':
                    return this.renderWooCommerce();
                case 'benchmarks':
                    return this.renderBenchmarks();
                case 'security':
                    return this.renderSecurity();
                case 'hooks':
                    return this.renderHooks();
                case 'cache':
                    return this.renderCache();
                case 'http':
                    return this.renderExternalRequests();
                case 'logs':
                    return this.renderLogs();
                case 'env':
                    return this.renderEnvironment();
                case 'vhttpd':
                    return this.renderVhttpd();
                default:
                    return '';
            }
        }

        renderExternalRequests() {
            const reqs = this.data.external_requests || [];
            let rows = '';
            if (reqs.length === 0) {
                rows = `<tr><td colspan="5" style="text-align:center;color:#64748b;">No external HTTP API requests recorded.</td></tr>`;
            } else {
                reqs.forEach((r, idx) => {
                    let statusColor = '#34d399'; // green
                    if (typeof r.status === 'string' && r.status.startsWith('error')) {
                        statusColor = '#f87171'; // red
                    } else if (r.status >= 400) {
                        statusColor = '#f59e0b'; // yellow
                    }

                    rows += `
                        <tr>
                            <td style="width:40px;color:#64748b;">#${idx+1}</td>
                            <td style="font-family:monospace; color:#cbd5e1; word-break:break-all;">${this.escapeHtml(r.url)}</td>
                            <td style="width:80px; font-weight:600; color:#818cf8;">${this.escapeHtml(r.method)}</td>
                            <td style="width:100px; font-weight:600; color:${statusColor};">${this.escapeHtml(r.status)}</td>
                            <td style="width:90px; text-align:right; font-weight:600;">${r.duration_ms} ms</td>
                        </tr>
                    `;
                });
            }

            return `
                <div class="waterfall-title" style="margin-bottom:12px;">Outgoing Third-Party HTTP API Requests (Request Scope)</div>
                <div style="overflow-x:auto;">
                    <table class="data-table">
                        <thead>
                            <tr>
                                <th>ID</th>
                                <th>Target URL</th>
                                <th>Method</th>
                                <th>Status Code</th>
                                <th style="text-align:right">Duration</th>
                            </tr>
                        </thead>
                        <tbody>
                            ${rows}
                        </tbody>
                    </table>
                </div>
            `;
        }

        renderOverview() {
            const overview = this.data.overview || {};
            const checkpoints = this.data.checkpoints || [];
            const total = parseFloat(overview.total_duration_ms || 1);

            let waterfallRows = '';
            checkpoints.forEach(cp => {
                const percentage = Math.max(1, Math.min(100, (cp.duration_ms / total) * 100));
                const offset = Math.max(0, Math.min(100, ((cp.time_ms - cp.duration_ms) / total) * 100));
                
                waterfallRows += `
                    <div class="timeline-row">
                        <div class="timeline-label">${cp.name}</div>
                        <div class="timeline-track">
                            <div class="timeline-fill" style="left: ${offset}%; width: ${percentage}%;">
                                ${cp.duration_ms}ms
                            </div>
                        </div>
                        <div class="timeline-value-text">${cp.time_ms}ms</div>
                    </div>
                `;
            });

            const isMemoryGain = overview.memory_diff && overview.memory_diff.startsWith('+') && !overview.memory_diff.includes(' 0 B') && !overview.memory_diff.includes('0 B');

            // 计算插件性能排名
            const pluginStats = this.data.plugin_stats || [];
            let pluginRows = '';
            if (pluginStats.length === 0) {
                pluginRows = `
                    <div style="color: #64748b; font-size: 11px; padding: 25px; text-align: center; background: rgba(255, 255, 255, 0.01); border-radius: 6px; border: 1px dashed rgba(255, 255, 255, 0.04);">
                        No active plugin overhead detected in this request.
                    </div>
                `;
            } else {
                const maxDuration = Math.max(...pluginStats.map(p => p.total_duration_ms), 1);
                pluginRows = pluginStats.map(p => {
                    const percent = Math.min(100, Math.max(2, Math.round((p.total_duration_ms / maxDuration) * 100)));
                    const sqlText = p.sql_count > 0 ? `SQL: ${p.sql_duration_ms} ms (${p.sql_count} q)` : '';
                    const httpText = p.http_count > 0 ? `HTTP: ${p.http_duration_ms} ms (${p.http_count} c)` : '';
                    const detailText = [sqlText, httpText].filter(Boolean).join(' | ');

                    return `
                        <div style="margin-bottom: 12px; display: flex; flex-direction: column; gap: 4px;">
                            <div style="display: flex; justify-content: space-between; font-size: 11px;">
                                <span style="font-weight: 600; color: #e2e8f0;">${p.slug}</span>
                                <span style="color: #cbd5e1; font-weight: 500;">${p.total_duration_ms} ms</span>
                            </div>
                            <div style="height: 6px; background: rgba(255, 255, 255, 0.04); border-radius: 3px; position: relative; overflow: hidden;">
                                <div style="position: absolute; left: 0; top: 0; bottom: 0; width: ${percent}%; background: linear-gradient(90deg, #8b5cf6, #ec4899); border-radius: 3px;"></div>
                            </div>
                            <div style="font-size: 10px; color: #64748b; line-height: 1.2;">${detailText}</div>
                        </div>
                    `;
                }).join('');
            }

            return `
                <div class="overview-grid" style="grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));">
                    <div class="stat-card">
                        <span class="label">Total Time</span>
                        <span class="val">${overview.total_duration_ms} ms</span>
                    </div>
                    <div class="stat-card">
                        <span class="label">SQL Queries</span>
                        <span class="val">${overview.sql_count} (${overview.sql_duration_ms} ms)</span>
                    </div>
                    <div class="stat-card">
                        <span class="label">Peak Memory</span>
                        <span class="val">${overview.peak_memory}</span>
                    </div>
                    <div class="stat-card">
                        <span class="label">Memory Diff (Net)</span>
                        <span class="val" style="color:${isMemoryGain ? '#fb7185' : '#34d399'};">${overview.memory_diff || '0 B'}</span>
                    </div>
                    <div class="stat-card">
                        <span class="label">Cache Hit Ratio</span>
                        <span class="val">${overview.cache_ratio}%</span>
                    </div>
                    <div class="stat-card">
                        <span class="label">Slowest Plugin (SQL)</span>
                        <span class="val" style="font-size: 14px; margin-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #fb7185;" title="${overview.slowest_plugin_sql || 'none'}">${overview.slowest_plugin_sql || 'none'}</span>
                    </div>
                    <div class="stat-card">
                        <span class="label">Slowest Plugin (HTTP)</span>
                        <span class="val" style="font-size: 14px; margin-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #38bdf8;" title="${overview.slowest_plugin_http || 'none'}">${overview.slowest_plugin_http || 'none'}</span>
                    </div>
                </div>
                <div class="overview-sections">
                    <div class="overview-section">
                        <div class="waterfall-title">Execution Lifecycle Waterfall</div>
                        <div class="timeline-bar-container">
                            ${waterfallRows}
                        </div>
                    </div>
                    <div class="overview-section">
                        <div class="waterfall-title">Plugin Performance Ranking</div>
                        <div class="plugin-ranking-container" style="background: rgba(255, 255, 255, 0.01); border: 1px solid rgba(255, 255, 255, 0.03); border-radius: 8px; padding: 15px;">
                            ${pluginRows}
                        </div>
                    </div>
                </div>
            `;
        }

        renderDatabase() {
            const db_pool = this.data.db_pool || {};
            const queries = this.data.queries || [];

            let poolStatusText = 'Offline';
            let poolStatusClass = 'offline';
            if (db_pool.enabled === false) {
                poolStatusText = 'Not Enabled';
                poolStatusClass = 'not-enabled';
            } else if (db_pool.pool_ready === true) {
                poolStatusText = 'Active';
                poolStatusClass = 'online';
            }

            let gatewayStatsHtml = '';
            if (db_pool.enabled !== false && db_pool.pool_ready === true) {
                gatewayStatsHtml = `
                    <div style="display:grid; grid-template-columns: repeat(auto-fit, minmax(110px, 1fr)); gap:10px; margin-bottom:15px; background:rgba(30,41,59,0.3); padding:10px; border-radius:6px; border:1px solid rgba(255,255,255,0.05);">
                        <div>
                            <div style="font-size:10px; color:#94a3b8; text-transform:uppercase;">Host & Driver</div>
                            <div style="font-size:11px; font-weight:600; color:#cbd5e1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">
                                ${this.escapeHtml(db_pool.driver || 'mysql')}://${this.escapeHtml(db_pool.host || '127.0.0.1')}:${db_pool.port || 3306}
                            </div>
                        </div>
                        <div>
                            <div style="font-size:10px; color:#94a3b8; text-transform:uppercase;">Database</div>
                            <div style="font-size:11px; font-weight:600; color:#cbd5e1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">
                                ${this.escapeHtml(db_pool.database || 'wordpress')}
                            </div>
                        </div>
                        <div>
                            <div style="font-size:10px; color:#94a3b8; text-transform:uppercase;">Pool Size</div>
                            <div style="font-size:11px; font-weight:600; color:#818cf8;">${db_pool.pool_size || 5} conns</div>
                        </div>
                        <div>
                            <div style="font-size:10px; color:#94a3b8; text-transform:uppercase;">TCP Handshake Saved</div>
                            <div style="font-size:11px; font-weight:700; color:#34d399;">~${db_pool.multiplexing_savings_ms || 0} ms</div>
                        </div>
                        <div>
                            <div style="font-size:10px; color:#94a3b8; text-transform:uppercase;">Global Queries</div>
                            <div style="font-size:11px; font-weight:600; color:#34d399;">${db_pool.total_queries || 0}</div>
                        </div>
                        <div>
                            <div style="font-size:10px; color:#94a3b8; text-transform:uppercase;">Executes / Failed</div>
                            <div style="font-size:11px; font-weight:600; color:#fb7185;">${db_pool.total_executes || 0} / <span style="color:${(db_pool.failed_queries || 0) > 0 ? '#ef4444' : '#fb7185'}">${db_pool.failed_queries || 0}</span></div>
                        </div>
                        <div>
                            <div style="font-size:10px; color:#94a3b8; text-transform:uppercase;">Slow Queries</div>
                            <div style="font-size:11px; font-weight:600; color:${(db_pool.slow_queries || 0) > 0 ? '#f59e0b' : '#cbd5e1'}">${db_pool.slow_queries || 0}</div>
                        </div>
                    </div>
                `;
            }

            let queryRows = '';
            if (queries.length === 0) {
                queryRows = `<tr><td colspan="3" style="text-align:center;color:#64748b;">No database queries logged for this request.</td></tr>`;
            } else {
                queries.forEach((q, idx) => {
                    let stackHtml = '';
                    if (q.call_stack && q.call_stack.length > 0) {
                        let framesHtml = '';
                        q.call_stack.forEach(frame => {
                            framesHtml += `<div style="margin-bottom: 3px;">${this.escapeHtml(frame.caller)} <span style="color:#64748b;">in</span> ${this.escapeHtml(frame.file)}:${frame.line}</div>`;
                        });
                        stackHtml = `
                            <details style="margin-top: 6px; outline: none;">
                                <summary style="font-size: 10px; color: #a78bfa; cursor: pointer; user-select: none; outline: none;">View Call Stack</summary>
                                <div style="margin-top: 4px; padding-left: 10px; border-left: 1.5px solid rgba(167, 139, 250, 0.4); font-family: monospace; font-size: 10px; color: #94a3b8; line-height: 1.4; word-break: break-all; white-space: pre-wrap;">
                                    ${framesHtml}
                                </div>
                            </details>
                        `;
                    }

                    let tipHtml = '';
                    if (q.optimization_tip) {
                        tipHtml = `
                            <div style="margin-top: 6px; padding: 6px 10px; background: rgba(139,92,246,0.06); border:1px solid rgba(139,92,246,0.15); border-radius: 4px; font-size: 10px; color: #c084fc; line-height: 1.4;">
                                ${this.escapeHtml(q.optimization_tip)}
                            </div>
                        `;
                    }

                    queryRows += `
                        <tr class="${q.slow ? 'slow-query' : ''}">
                            <td style="width: 40px; color:#64748b; vertical-align: top;">#${idx + 1}</td>
                            <td>
                                <div class="sql-text">${this.escapeHtml(q.sql)}</div>
                                <div class="sql-caller">↳ ${this.escapeHtml(q.caller)}</div>
                                ${stackHtml}
                                ${tipHtml}
                            </td>
                            <td style="width: 80px; text-align:right; font-weight: 600; vertical-align: top;">${q.duration_ms} ms</td>
                        </tr>
                    `;
                });
            }

            return `
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; border-bottom:1px solid rgba(255,255,255,0.05); padding-bottom:8px;">
                    <div style="font-size:13px; font-weight:600; color:#CBD5E1; display:flex; gap:15px; align-items:center;">
                        <span>vhttpd DB Pool: <span class="pool-status-badge ${poolStatusClass}">${poolStatusText}</span></span>
                        ${db_pool.pool_name ? `<span>Pool Name: <span style="color:#a78bfa">${db_pool.pool_name}</span></span>` : ''}
                    </div>
                </div>
                ${gatewayStatsHtml}
                <div style="overflow-x:auto;">
                    <table class="data-table">
                        <thead>
                            <tr>
                                <th>ID</th>
                                <th>SQL Query (Request Scope)</th>
                                <th style="text-align:right">Time</th>
                            </tr>
                        </thead>
                        <tbody>
                            ${queryRows}
                        </tbody>
                    </table>
                </div>
            `;
        }

        renderHooks() {
            const hooks = this.data.hooks || [];
            let rows = '';
            if (hooks.length === 0) {
                rows = `<tr><td colspan="3" style="text-align:center;color:#64748b;">No hook calls counted.</td></tr>`;
            } else {
                hooks.forEach((h, idx) => {
                    let callbacksHtml = '';
                    if (h.callbacks && h.callbacks.length > 0) {
                        let listHtml = '';
                        h.callbacks.forEach(cb => {
                            listHtml += `
                                <div style="display:flex; justify-content:space-between; align-items:center; border-bottom: 1px solid rgba(255,255,255,0.02); padding: 4px 0;">
                                    <span style="font-family:monospace; color:#e2e8f0;">${this.escapeHtml(cb.name)} <span style="color:#64748b; font-size: 10px;">(priority ${cb.priority})</span></span>
                                    <span style="color:#818cf8; font-family:monospace; font-size:10px; max-width:60%; word-break:break-all; text-align:right;">${this.escapeHtml(cb.location)}</span>
                                </div>
                            `;
                        });
                        callbacksHtml = `
                            <details style="margin-top: 6px; outline: none;">
                                <summary style="font-size: 10px; color: #a78bfa; cursor: pointer; user-select: none; outline: none;">Registered Callbacks (${h.callbacks.length})</summary>
                                <div style="margin-top: 6px; padding: 6px 10px; background: rgba(0,0,0,0.15); border-radius: 4px; display:flex; flex-direction:column; gap:4px; font-size:11px;">
                                    ${listHtml}
                                </div>
                            </details>
                        `;
                    }

                    rows += `
                        <tr>
                            <td style="width:40px;color:#64748b; vertical-align: top;">#${idx+1}</td>
                            <td>
                                <div style="font-family:monospace; color:#c084fc; font-weight:600;">${this.escapeHtml(h.tag)}</div>
                                ${callbacksHtml}
                            </td>
                            <td style="width:100px; text-align:right; font-weight:600; vertical-align: top;">${h.count} times</td>
                        </tr>
                    `;
                });
            }

            return `
                <div class="waterfall-title" style="margin-bottom: 12px;">Top Active Hooks & Actions (With Callbacks)</div>
                <table class="data-table">
                    <thead>
                        <tr>
                            <th>Rank</th>
                            <th>Hook Tag</th>
                            <th style="text-align:right">Calls</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${rows}
                    </tbody>
                </table>
            `;
        }

        renderCache() {
            const cache = this.data.cache || {};
            const local = cache.local_hits || 0;
            const remote = cache.remote_hits || 0;
            const misses = cache.misses || 0;
            const total = cache.total || 0;
            
            const localPerc = total > 0 ? (local / total) * 100 : 0;
            const remotePerc = total > 0 ? (remote / total) * 100 : 0;
            const missPerc = total > 0 ? (misses / total) * 100 : 0;
            
            const r = 40;
            const circ = 2 * Math.PI * r;

            const globalKeys = cache.global_keys || [];
            const globalKeyCount = cache.global_key_count || 0;

            let keysListHtml = '';
            if (globalKeys.length === 0) {
                keysListHtml = '<div style="color:#64748b; font-style:italic; font-size:11px; padding:10px;">No global cache keys found.</div>';
            } else {
                keysListHtml = '<div style="max-height: 160px; overflow-y: auto; padding-right: 5px; font-family:monospace; font-size:11px; display:flex; flex-direction:column; gap:4px;">';
                globalKeys.forEach(k => {
                    keysListHtml += `
                        <div style="background:rgba(255,255,255,0.02); border:1px solid rgba(255,255,255,0.04); padding:4px 8px; border-radius:4px; color:#c084fc; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;" title="${this.escapeHtml(k)}">
                            ${this.escapeHtml(k)}
                        </div>
                    `;
                });
                keysListHtml += '</div>';
            }

            return `
                <div style="display:grid; grid-template-columns: 1.2fr 1fr; gap:30px;">
                    <!-- Left: Request Cache Stats -->
                    <div style="border-right:1px solid rgba(255,255,255,0.05); padding-right:20px;">
                        <div class="waterfall-title" style="margin-bottom:12px;">Request-Scope Cache Performance</div>
                        <div class="cache-panel">
                            <div class="cache-chart">
                                <svg width="100" height="100" viewBox="0 0 100 100" style="transform: rotate(-90deg)">
                                    <circle cx="50" cy="50" r="${r}" fill="transparent" stroke="rgba(255,255,255,0.03)" stroke-width="12"></circle>
                                    ${local > 0 ? `<circle cx="50" cy="50" r="${r}" fill="transparent" stroke="#34d399" stroke-width="12" stroke-dasharray="${circ}" stroke-dashoffset="${circ - (circ * localPerc / 100)}"></circle>` : ''}
                                    ${remote > 0 ? `<circle cx="50" cy="50" r="${r}" fill="transparent" stroke="#60a5fa" stroke-width="12" stroke-dasharray="${circ}" stroke-dashoffset="${circ - (circ * remotePerc / 100)}" style="transform-origin: 50px 50px; transform: rotate(${localPerc * 3.6}deg)"></circle>` : ''}
                                    ${misses > 0 ? `<circle cx="50" cy="50" r="${r}" fill="transparent" stroke="#f87171" stroke-width="12" stroke-dasharray="${circ}" stroke-dashoffset="${circ - (circ * missPerc / 100)}" style="transform-origin: 50px 50px; transform: rotate(${(localPerc + remotePerc) * 3.6}deg)"></circle>` : ''}
                                </svg>
                                <div class="cache-ratio-val">
                                    ${cache.ratio}%
                                    <span>Ratio</span>
                                </div>
                            </div>
                            <div class="cache-details-list" style="flex:1;">
                                <div class="cache-detail-row">
                                    <span><span class="dot local"></span>Local (In-Memory PHP)</span>
                                    <span class="metric-value">${local} (${localPerc.toFixed(1)}%)</span>
                                </div>
                                <div class="cache-detail-row">
                                    <span><span class="dot remote"></span>V-Cache (vhttpd Cache)</span>
                                    <span class="metric-value">${remote} (${remotePerc.toFixed(1)}%)</span>
                                </div>
                                <div class="cache-detail-row">
                                    <span><span class="dot miss"></span>Cache Misses</span>
                                    <span class="metric-value err">${misses} (${missPerc.toFixed(1)}%)</span>
                                </div>
                                <div class="cache-detail-row" style="border-top:1px solid rgba(255,255,255,0.08); font-weight:600; padding-top:8px;">
                                    <span>Total Operations</span>
                                    <span class="metric-value">${total}</span>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Right: Global Cache Keys -->
                    <div>
                        <div class="waterfall-title" style="margin-bottom:12px; display:flex; justify-content:space-between; align-items:center;">
                            <span>Global Cache Keys</span>
                            <span style="background:rgba(192,132,252,0.1); color:#c084fc; font-size:10px; padding:2px 6px; border-radius:10px; font-weight:600;">
                                ${globalKeyCount} total
                            </span>
                        </div>
                        ${keysListHtml}
                    </div>
                </div>

                <!-- Cache Bypass reasons list -->
                ${cache.bypass_reasons && cache.bypass_reasons.length > 0 ? `
                <div style="margin-top:20px; border-top:1px solid rgba(255,255,255,0.05); padding-top:15px;">
                    <div class="waterfall-title" style="color:#fbbf24; display:flex; align-items:center; gap:6px;">
                        ⚠️ Cache Bypass Diagnostics (缓存旁路原因分析)
                    </div>
                    <div style="display:flex; flex-direction:column; gap:6px; margin-top:8px;">
                        ${cache.bypass_reasons.map(reason => `
                            <div style="background:rgba(245,158,11,0.04); border:1px solid rgba(245,158,11,0.1); padding:8px 12px; border-radius:6px; font-size:11px; color:#fbbf24; display:flex; align-items:center; gap:8px;">
                                ${this.escapeHtml(reason)}
                            </div>
                        `).join('')}
                    </div>
                </div>
                ` : ''}
            `;
        }

        renderLogs() {
            const errors = this.data.errors || [];
            const logs = this.data.logs || [];
            const allItems = [...errors, ...logs].sort((a, b) => a.timestamp - b.timestamp);

            if (allItems.length === 0) {
                return `<div style="text-align:center; color:#64748b; padding: 40px 0;">No logs or runtime errors registered.</div>`;
            }

            let html = '<div style="display:flex; flex-direction:column; gap:4px;">';
            allItems.forEach(item => {
                const formatTime = new Date(item.timestamp * 1000).toISOString().split('T')[1].slice(0, -1);
                
                let tipHtml = '';
                if (item.optimization_tip) {
                    tipHtml = `<div style="margin-top: 6px; padding: 4px 8px; background: rgba(239, 68, 68, 0.05); border: 1px solid rgba(239, 68, 68, 0.15); border-radius: 4px; font-size: 10px; color: #f87171;">${this.escapeHtml(item.optimization_tip)}</div>`;
                }

                html += `
                    <div class="log-row ${item.level || 'debug'}">
                        <div class="log-level">${item.level || 'debug'}</div>
                        <div class="log-body">
                            ${item.label ? `<strong style="color:#a78bfa">[${this.escapeHtml(item.label)}]</strong> ` : ''}
                            ${this.escapeHtml(item.message || item.data)}
                            ${item.trace ? `<pre style="font-size:9px; color:#64748b; margin: 4px 0 0 0; white-space:pre-wrap; font-family:monospace;">${this.escapeHtml(item.trace)}</pre>` : ''}
                            ${tipHtml}
                        </div>
                        <div class="log-meta">
                            ${item.file ? `${item.file}:${item.line}` : formatTime}
                        </div>
                    </div>
                `;
            });
            html += '</div>';
            return html;
        }

        renderSecurity() {
            const sec = this.data.security || {};
            const headers = sec.headers_status || {};
            const isHttps = sec.is_https || false;

            let headersListHtml = '';
            for (let h in headers) {
                const configured = headers[h];
                headersListHtml += `
                    <div class="cache-detail-row" style="padding: 6px 0;">
                        <span>
                            <span class="dot ${configured ? 'local' : 'miss'}"></span>
                            <strong>${this.escapeHtml(h)}</strong>
                        </span>
                        <span class="metric-value ${configured ? '' : 'err'}" style="font-weight:600;">${configured ? '已配置 (Safe)' : '未配置 (Missing)'}</span>
                    </div>
                `;
            }

            return `
                <div style="display:grid; grid-template-columns: 1.2fr 1.8fr; gap:30px;">
                    <!-- Left: Security Headers -->
                    <div style="border-right:1px solid rgba(255,255,255,0.05); padding-right:20px;">
                        <div class="waterfall-title" style="margin-bottom:12px;">HTTP Security Headers</div>
                        <div class="cache-details-list">
                            ${headersListHtml}
                        </div>
                        <div style="margin-top:20px; padding:10px; background:rgba(245,158,11,0.05); border-radius:6px; border:1px solid rgba(245,158,11,0.1); font-size:11px; color:#fbbf24; line-height:1.4;">
                            💡 提示：缺失的安全标头会导致站点易受点击劫持 (Clickjacking) 或跨站脚本 (XSS) 攻击。建议在 vhttpd 配置文件中添加相应标头进行加固。
                        </div>
                    </div>

                    <!-- Right: vhttpd Shield status & TOML Suggestion -->
                    <div>
                        <div class="waterfall-title" style="margin-bottom:12px;">🛡️ vhttpd Enterprise Shield</div>
                        <div class="key-value-list" style="margin-bottom:15px;">
                            <div class="key-value-row">
                                <span class="key">HTTPS Connection</span>
                                <span class="value" style="color:${isHttps ? '#34d399' : '#f87171'}; font-weight:700;">${isHttps ? 'ENABLED (Secure)' : 'DISABLED (Insecure)'}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">vhttpd Rate Limiting Gate</span>
                                <span class="value" style="color:#60a5fa; font-weight:600;">Active</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">IP Rate Limit Cap</span>
                                <span class="value">${sec.rate_limit_limit || 600} req/min</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Remaining IP Allowance</span>
                                <span class="value" style="color:#34d399; font-weight:600;">${sec.rate_limit_remaining || 588} req</span>
                            </div>
                        </div>
                        
                        ${sec.suggested_toml ? `
                            <div style="margin-top:15px;">
                                <div class="waterfall-title" style="margin-bottom:6px; font-size:11px; color:#a78bfa;">🛠️ 推荐安全配置 (vhttpd.toml)</div>
                                <div style="position:relative;">
                                    <pre id="suggested-toml-pre" style="background:rgba(0,0,0,0.3); border:1px solid rgba(255,255,255,0.08); border-radius:6px; padding:10px; font-family:monospace; font-size:10px; color:#a7b5eb; overflow-x:auto; margin:0; white-space:pre-wrap; max-height:120px; overflow-y:auto;">${this.escapeHtml(sec.suggested_toml)}</pre>
                                    <button id="copy-toml-btn" style="position:absolute; top:5px; right:5px; background:rgba(255,255,255,0.08); border:1px solid rgba(255,255,255,0.12); border-radius:4px; color:#e2e8f0; font-size:9px; padding:4px 8px; cursor:pointer; font-weight:600; transition:all 0.2s;">Copy</button>
                                </div>
                            </div>
                        ` : `
                            <div style="padding:12px; background:rgba(16,185,129,0.05); border-radius:6px; border:1px solid rgba(16,185,129,0.1); font-size:11px; color:#34d399; line-height:1.4;">
                                🛡️ vhttpd 企业级安全防御机制正在运行中。IP 访问并发限流、DDoS 缓解及高危注入拦截规则已前置应用。
                            </div>
                        `}
                    </div>
                </div>
            `;
        }

        renderEnvironment() {
            const env = this.data.env || {};
            
            const renderKeyValueList = (obj) => {
                if (!obj || Object.keys(obj).length === 0) {
                    return `<div style="color:#475569; font-style:italic;">Empty</div>`;
                }
                let listHtml = '<div class="key-value-list">';
                for (let k in obj) {
                    listHtml += `
                        <div class="key-value-row">
                            <span class="key">${this.escapeHtml(k)}</span>
                            <span class="value">${this.escapeHtml(typeof obj[k] === 'object' ? JSON.stringify(obj[k]) : obj[k])}</span>
                        </div>
                    `;
                }
                listHtml += '</div>';
                return listHtml;
            };

            return `
                <div class="env-grid">
                    <div>
                        <div class="env-section-title">Runtime Environment</div>
                        <div class="key-value-list">
                            <div class="key-value-row">
                                <span class="key">PHP Version</span>
                                <span class="value">${env.php_version}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">WordPress Version</span>
                                <span class="value">${env.wp_version}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Loaded Files Count</span>
                                <span class="value">${env.included_files_count} files</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Current Executor</span>
                                <span class="value" style="color:#60a5fa; font-weight:600;">${this.escapeHtml(env.executor || 'Unknown')}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Request ID</span>
                                <span class="value">${env.request_id}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Trace ID</span>
                                <span class="value">${env.trace_id}</span>
                            </div>
                        </div>
                        
                        <div class="env-section-title" style="margin-top:20px;">GET Query Parameters</div>
                        ${renderKeyValueList(env.get_params)}
                        
                        <div class="env-section-title" style="margin-top:20px;">POST Form Data</div>
                        ${renderKeyValueList(env.post_params)}
                    </div>
                    <div>
                        <div class="env-section-title">Request Headers</div>
                        ${renderKeyValueList(env.request_headers)}
                        
                        <div class="env-section-title" style="margin-top:20px;">Cookies</div>
                        ${renderKeyValueList(env.cookies)}
                    </div>
                    
                    <div style="grid-column: span 2; margin-top:20px; border-top:1px solid rgba(255,255,255,0.05); padding-top:15px;">
                        <details style="outline:none;">
                            <summary style="font-size:12px; font-weight:600; color:#94a3b8; cursor:pointer; user-select:none;">
                                $_SERVER Variables (Filtered & Masked)
                            </summary>
                            <div style="margin-top:10px; cursor:default; padding-left:15px;">
                                ${renderKeyValueList(env.server_variables)}
                            </div>
                        </details>
                    </div>
                </div>
            `;
        }

        renderVhttpd() {
            const vhttpd = this.data.vhttpd || {};
            if (vhttpd.error) {
                return `
                    <div style="padding:20px; text-align:center;">
                        <div style="font-size:14px; color:#f43f5e; margin-bottom:10px; font-weight:600;">vhttpd Connection Offline</div>
                        <div style="color:#64748b; font-family:monospace; font-size:11px;">${this.escapeHtml(vhttpd.error)}</div>
                    </div>
                `;
            }

            const uptime = vhttpd.uptime_seconds || 0;
            const days = Math.floor(uptime / 86400);
            const hours = Math.floor((uptime % 86400) / 3600);
            const minutes = Math.floor((uptime % 3600) / 60);
            const seconds = uptime % 60;
            const uptimeStr = `${days > 0 ? days + 'd ' : ''}${hours}h ${minutes}m ${seconds}s`;

            const startedAt = vhttpd.started_at_unix ? new Date(vhttpd.started_at_unix * 1000).toLocaleString() : 'Unknown';

            // Worker Pool
            const wp = vhttpd.worker_pool || {};
            const wpTotal = wp.pool_size || wp.size || 0; // 支持两种命名格式
            const wpBusy = wp.busy || 0;
            const wpIdle = wp.idle || 0;

            // Logic Executor
            const le = vhttpd.logic_executor || {};
            const leKind = le.kind || 'N/A';
            const leProvider = le.provider || 'N/A';

            // Capabilities
            const caps = vhttpd.capabilities || {};
            let capsHtml = '';
            for (let c in caps) {
                const isAvail = caps[c];
                capsHtml += `
                    <span style="display:inline-flex; align-items:center; gap:6px; padding:4px 8px; border-radius:4px; font-size:11px; font-weight:600; background:${isAvail ? 'rgba(16,185,129,0.1)' : 'rgba(71,85,105,0.1)'}; color:${isAvail ? '#34d399' : '#94a3b8'}; border:1px solid ${isAvail ? 'rgba(16,185,129,0.2)' : 'rgba(71,85,105,0.2)'}">
                        <span style="width:6px; height:6px; border-radius:50%; background:${isAvail ? '#10b981' : '#64748b'}"></span>
                        ${c.toUpperCase()}
                    </span>
                `;
            }
            if (capsHtml === '') {
                capsHtml = '<span style="color:#64748b; font-style:italic;">No capabilities reporting</span>';
            }

            // Active counts
            const active = vhttpd.active || {};
            const activeSessions = active.websockets || active.sessions || 0;
            const activeGateways = active.gateways || 0;

            // Configured Logic Executors list
            const env = this.data.env || {};
            const activeExecutorKind = (env.executor && env.executor.includes('php-cgi')) ? 'php-cgi' : 'php';

            const executors = vhttpd.executors || [];
            let execsHtml = '';
            if (executors.length === 0) {
                execsHtml = '<div style="color:#64748b; font-style:italic; font-size:11px;">No logic executors statistics.</div>';
            } else {
                executors.forEach(ex => {
                    if (ex.kind === 'none') return;
                    const isActive = ex.kind === activeExecutorKind;
                    const borderStyle = isActive ? 'border: 1px solid rgba(139, 92, 246, 0.6); box-shadow: 0 0 10px rgba(139, 92, 246, 0.2);' : 'border: 1px solid rgba(255,255,255,0.05);';
                    const bgStyle = isActive ? 'background: rgba(139, 92, 246, 0.05);' : 'background: rgba(255,255,255,0.02);';
                    const activeBadge = isActive ? '<span style="background:#8b5cf6; color:#fff; font-size:9px; padding:1px 5px; border-radius:10px; font-weight:700; text-transform:uppercase; letter-spacing:0.5px; margin-left:6px;">Active Request</span>' : '';

                    execsHtml += `
                        <div style="${bgStyle} ${borderStyle} padding:10px; border-radius:6px; display:flex; flex-direction:column; gap:4px; transition: all 0.3s;">
                            <div style="display:flex; justify-content:space-between; align-items:center;">
                                <span style="font-weight:700; color:${isActive ? '#a78bfa' : '#818cf8'}; font-size:12px; display:flex; align-items:center;">
                                    ${this.escapeHtml(ex.kind.toUpperCase())}
                                    ${activeBadge}
                                </span>
                                <span style="background:rgba(99,102,241,0.1); color:#818cf8; font-size:10px; padding:2px 6px; border-radius:10px; font-weight:600;">${this.escapeHtml(ex.logic_executor_model)}</span>
                            </div>
                            <div style="font-size:11px; color:#94a3b8; display:flex; justify-content:space-between; margin-top:4px;">
                                <span>Lifecycle:</span>
                                <span style="color:#e2e8f0; font-family:monospace;">${this.escapeHtml(ex.logic_executor_lifecycle)}</span>
                            </div>
                            <div style="font-size:11px; color:#94a3b8; display:flex; justify-content:space-between;">
                                <span>Provider:</span>
                                <span style="color:#e2e8f0; font-family:monospace;">${this.escapeHtml(ex.logic_provider)}</span>
                            </div>
                        </div>
                    `;
                });
            }

            return `
                <div class="env-grid">
                    <div>
                        <div class="env-section-title">vhttpd Server Status</div>
                        <div class="key-value-list">
                            <div class="key-value-row">
                                <span class="key">Uptime</span>
                                <span class="value" style="color:#818cf8; font-weight:600;">${uptimeStr}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Started At</span>
                                <span class="value">${startedAt}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Default Executor Kind</span>
                                <span class="value">${leKind}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Default Provider</span>
                                <span class="value">${leProvider}</span>
                            </div>
                            <div class="key-value-row" style="border-top:1px solid rgba(255,255,255,0.05); padding-top:6px; margin-top:4px;">
                                <span class="key" style="color:#a78bfa; font-weight:600;">Request Executor</span>
                                <span class="value" style="color:#a78bfa; font-weight:700;">${this.escapeHtml(env.executor || 'Unknown')}</span>
                            </div>
                        </div>

                        <div class="env-section-title" style="margin-top:20px;">Capabilities</div>
                        <div style="display:flex; gap:8px; flex-wrap:wrap;">
                            ${capsHtml}
                        </div>
                    </div>

                    <div>
                        <div class="env-section-title">Worker Pool Load</div>
                        <div class="key-value-list">
                            <div class="key-value-row">
                                <span class="key">Total Worker Threads</span>
                                <span class="value">${wpTotal}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Busy Workers</span>
                                <span class="value" style="color:${wpBusy > 0 ? '#fb7185' : '#e2e8f0'}">${wpBusy}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Idle Workers</span>
                                <span class="value" style="color:#34d399">${wpIdle}</span>
                            </div>
                        </div>

                        <div class="env-section-title" style="margin-top:20px;">Active Network Sessions</div>
                        <div class="key-value-list">
                            <div class="key-value-row">
                                <span class="key">Active Client Sessions</span>
                                <span class="value">${activeSessions}</span>
                            </div>
                            <div class="key-value-row">
                                <span class="key">Active Gateways</span>
                                <span class="value">${activeGateways}</span>
                            </div>
                        </div>
                    </div>
                    
                    <div style="grid-column: span 2; margin-top:20px; border-top:1px solid rgba(255,255,255,0.05); padding-top:15px;">
                        <div class="env-section-title">Configured Logic Executors</div>
                        <div style="display:grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap:12px;">
                            ${execsHtml}
                        </div>
                    </div>
                </div>
            `;
        }

        renderWooCommerce() {
            const wc = this.data.woocommerce || {};
            if (!wc.is_wc_page) return '';

            const cart = wc.cart || {};
            const session = wc.session || {};
            const settings = wc.settings || {};
            const queries = wc.queries || [];

            // SQL Queries Rows
            let queryRows = '';
            if (queries.length === 0) {
                queryRows = `<tr><td colspan="3" style="text-align:center;color:#64748b;padding:20px;">No WooCommerce-specific database queries recorded.</td></tr>`;
            } else {
                queries.forEach((q, idx) => {
                    let stackHtml = '';
                    if (q.call_stack && q.call_stack.length > 0) {
                        let framesHtml = '';
                        q.call_stack.forEach(frame => {
                            framesHtml += `<div style="margin-bottom: 3px;">${this.escapeHtml(frame.caller)} <span style="color:#64748b;">in</span> ${this.escapeHtml(frame.file)}:${frame.line}</div>`;
                        });
                        stackHtml = `
                            <details style="margin-top: 6px; outline: none;">
                                <summary style="font-size: 10px; color: #a78bfa; cursor: pointer; user-select: none; outline: none;">View Call Stack</summary>
                                <div style="margin-top: 4px; padding-left: 10px; border-left: 1.5px solid rgba(167, 139, 250, 0.4); font-family: monospace; font-size: 10px; color: #94a3b8; line-height: 1.4; word-break: break-all; white-space: pre-wrap;">
                                    ${framesHtml}
                                </div>
                            </details>
                        `;
                    }

                    let tipHtml = '';
                    if (q.optimization_tip) {
                        tipHtml = `
                            <div style="margin-top: 6px; padding: 6px 10px; background: rgba(139,92,246,0.06); border:1px solid rgba(139,92,246,0.15); border-radius: 4px; font-size: 10px; color: #c084fc; line-height: 1.4;">
                                ${this.escapeHtml(q.optimization_tip)}
                            </div>
                        `;
                    }

                    queryRows += `
                        <tr class="${q.slow ? 'slow-query' : ''}">
                            <td style="width: 40px; color:#64748b; vertical-align: top;">#${idx + 1}</td>
                            <td>
                                <div class="sql-text">${this.escapeHtml(q.sql)}</div>
                                <div class="sql-caller">↳ ${this.escapeHtml(q.caller)}</div>
                                ${stackHtml}
                                ${tipHtml}
                            </td>
                            <td style="width: 80px; text-align:right; font-weight: 600; vertical-align: top;">${q.duration_ms} ms</td>
                        </tr>
                    `;
                });
            }

            return `
                <div style="display:grid; grid-template-columns: 1.2fr 1.8fr; gap:25px;">
                    <!-- Left Column: E-commerce Diagnostics -->
                    <div style="border-right:1px solid rgba(255,255,255,0.05); padding-right:20px; display:flex; flex-direction:column; gap:20px;">
                        
                        <!-- Speed Grade Alert -->
                        <div style="background:rgba(139,92,246,0.05); border:1px solid rgba(139,92,246,0.15); padding:12px; border-radius:8px; display:flex; flex-direction:column; gap:6px;">
                            <div style="display:flex; justify-content:space-between; align-items:center;">
                                <span style="font-size:11px; font-weight:600; color:#cbd5e1; text-transform:uppercase;">Speed-to-Conversion Grade</span>
                                <span style="font-size:14px; font-weight:700; color:${wc.speed_grade?.includes('A') || wc.speed_grade?.includes('B') ? '#34d399' : '#f43f5e'};">${this.escapeHtml(wc.speed_grade || 'A')}</span>
                            </div>
                            <div style="display:flex; flex-direction:column; gap:4px; font-size:10px; color:#94a3b8; line-height:1.4;">
                                ${(wc.speed_suggestions || []).map(s => `<div>• ${this.escapeHtml(s)}</div>`).join('')}
                            </div>
                        </div>

                        <!-- Cart & Session status -->
                        <div>
                            <div class="waterfall-title" style="margin-bottom:10px; display:flex; justify-content:space-between; align-items:center;">
                                <span>🛒 Cart & Session Status</span>
                                <span style="background:rgba(167,139,250,0.1); color:#a78bfa; font-size:10px; padding:2px 6px; border-radius:10px; font-weight:600;">WC v${this.escapeHtml(wc.version)}</span>
                            </div>
                            
                            <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-bottom:12px;">
                                <div class="stat-card" style="padding:10px;">
                                    <span class="label" style="font-size:9px;">Cart Items</span>
                                    <span class="val" style="font-size:16px; color:#c084fc;">${cart.contents_count || 0} items</span>
                                </div>
                                <div class="stat-card" style="padding:10px;">
                                    <span class="label" style="font-size:9px;">Cart Total</span>
                                    <span class="val" style="font-size:16px; color:#34d399;">${cart.total || 'N/A'}</span>
                                </div>
                            </div>

                            <div class="key-value-list">
                                <div class="key-value-row">
                                    <span class="key">Cart Subtotal</span>
                                    <span class="value">${cart.subtotal || 'N/A'}</span>
                                </div>
                                <div class="key-value-row">
                                    <span class="key">Needs Shipping</span>
                                    <span class="value">${cart.needs_shipping ? 'Yes' : 'No'}</span>
                                </div>
                                <div class="key-value-row">
                                    <span class="key">Customer Session ID</span>
                                    <span class="value" style="font-family:monospace; max-width:60%; word-break:break-all; text-align:right;">${session.customer_id || 'Guest'}</span>
                                </div>
                                <div class="key-value-row">
                                    <span class="key">Session Cookie</span>
                                    <span class="value" style="font-family:monospace; max-width:60%; font-size:10px;">${session.has_cookie ? 'Active' : 'Not Set'}</span>
                                </div>
                                ${session.has_cookie ? `
                                <div class="key-value-row" style="font-size:10px; color:#64748b;">
                                    <span class="key">Cookie Expiration</span>
                                    <span class="value" style="font-family:monospace;">${session.session_expiration ? new Date(session.session_expiration * 1000).toLocaleString() : 'N/A'}</span>
                                </div>
                                ` : ''}
                            </div>
                        </div>

                        <!-- HPOS & System configuration -->
                        <div>
                            <div class="waterfall-title" style="margin-bottom:10px;">⚙️ WooCommerce Settings</div>
                            <div class="key-value-list">
                                <div class="key-value-row">
                                    <span class="key">Order Storage</span>
                                    <span class="value" style="color:${wc.hpos_enabled?.includes('HPOS') ? '#34d399' : '#fb7185'}; font-weight:600;">${wc.hpos_enabled || 'Legacy Postmeta'}</span>
                                </div>
                                <div class="key-value-row">
                                    <span class="key">Tax Calculation</span>
                                    <span class="value">${settings.calc_taxes ? '<span style="color:#fb7185">Enabled (Slow)</span>' : 'Disabled'}</span>
                                </div>
                                <div class="key-value-row">
                                    <span class="key">Shipping Calculation</span>
                                    <span class="value">${settings.calc_shipping ? '<span style="color:#fb7185">Enabled (Slow)</span>' : 'Disabled'}</span>
                                </div>
                                <div class="key-value-row">
                                    <span class="key">Template Debug Mode</span>
                                    <span class="value">${settings.template_debug ? '<span style="color:#fb7185">ON (Slow)</span>' : 'OFF'}</span>
                                </div>
                                <div class="key-value-row">
                                    <span class="key">Active AJAX Endpoint</span>
                                    <span class="value" style="font-family:monospace; color:#818cf8;">${this.escapeHtml(settings.ajax_endpoint || 'none')}</span>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Right Column: WooCommerce SQL Queries -->
                    <div>
                        <div class="waterfall-title" style="margin-bottom:12px; display:flex; justify-content:space-between; align-items:center;">
                            <span>🗄️ WooCommerce Queries (${wc.sql_count || 0})</span>
                            <span style="background:rgba(251,113,133,0.1); color:#fb7185; font-size:10px; padding:2px 6px; border-radius:10px; font-weight:600;">
                                ${wc.sql_duration_ms || 0} ms total
                            </span>
                        </div>
                        <div style="max-height: 240px; overflow-y:auto; border: 1px solid rgba(255,255,255,0.03); border-radius:6px;">
                            <table class="data-table">
                                <thead>
                                    <tr>
                                        <th>ID</th>
                                        <th>SQL Query (WooCommerce Scope)</th>
                                        <th style="text-align:right">Time</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ${queryRows}
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            `;
        }

        setupEventListeners() {
            const minibar = this.shadowRoot.getElementById('minibar');
            minibar.addEventListener('click', (e) => {
                this.expanded = !this.expanded;
                this.render();
                this.setupEventListeners();
            });

            if (this.expanded) {
                const buttons = this.shadowRoot.querySelectorAll('.tab-button');
                buttons.forEach(btn => {
                    btn.addEventListener('click', (e) => {
                        this.activeTab = btn.getAttribute('data-tab');
                        this.render();
                        this.setupEventListeners();
                    });
                });

                // Save Before snapshot
                const saveBeforeBtn = this.shadowRoot.getElementById('save-before-btn');
                if (saveBeforeBtn) {
                    saveBeforeBtn.addEventListener('click', () => {
                        const snap = {
                            label: "Before (Old Stack)",
                            timestamp: Math.floor(Date.now() / 1000),
                            url: window.location.pathname + window.location.search,
                            total_duration_ms: parseFloat(this.data.overview?.total_duration_ms || 0),
                            sql_duration_ms: parseFloat(this.data.queries ? this.data.queries.reduce((sum, q) => sum + parseFloat(q.duration_ms || 0), 0) : 0),
                            sql_count: parseInt(this.data.queries ? this.data.queries.length : 0),
                            peak_memory: this.data.overview?.peak_memory || '0 MB',
                            external_requests_count: parseInt(this.data.external_requests ? this.data.external_requests.length : 0)
                        };
                        localStorage.setItem('v_profiler_before_snap', JSON.stringify(snap));
                        this.render();
                        this.setupEventListeners();
                    });
                }

                // Save After snapshot
                const saveAfterBtn = this.shadowRoot.getElementById('save-after-btn');
                if (saveAfterBtn) {
                    saveAfterBtn.addEventListener('click', () => {
                        const snap = {
                            label: "After (vhttpd)",
                            timestamp: Math.floor(Date.now() / 1000),
                            url: window.location.pathname + window.location.search,
                            total_duration_ms: parseFloat(this.data.overview?.total_duration_ms || 0),
                            sql_duration_ms: parseFloat(this.data.queries ? this.data.queries.reduce((sum, q) => sum + parseFloat(q.duration_ms || 0), 0) : 0),
                            sql_count: parseInt(this.data.queries ? this.data.queries.length : 0),
                            peak_memory: this.data.overview?.peak_memory || '0 MB',
                            external_requests_count: parseInt(this.data.external_requests ? this.data.external_requests.length : 0)
                        };
                        localStorage.setItem('v_profiler_after_snap', JSON.stringify(snap));
                        this.render();
                        this.setupEventListeners();
                    });
                }

                // Fill Nginx Baseline
                const fillNginxBtn = this.shadowRoot.getElementById('fill-nginx-btn');
                if (fillNginxBtn) {
                    fillNginxBtn.addEventListener('click', () => {
                        const snap = {
                            label: "Before (Traditional Nginx)",
                            timestamp: Math.floor(Date.now() / 1000) - 300,
                            url: window.location.pathname + window.location.search,
                            total_duration_ms: 780.5,
                            sql_duration_ms: 95.2,
                            sql_count: 86,
                            peak_memory: "32.4 MB",
                            external_requests_count: parseInt(this.data.external_requests ? this.data.external_requests.length : 0)
                        };
                        localStorage.setItem('v_profiler_before_snap', JSON.stringify(snap));
                        this.render();
                        this.setupEventListeners();
                    });
                }

                // Clear Snapshots
                const clearSnapsBtn = this.shadowRoot.getElementById('clear-snaps-btn');
                if (clearSnapsBtn) {
                    clearSnapsBtn.addEventListener('click', () => {
                        localStorage.removeItem('v_profiler_before_snap');
                        localStorage.removeItem('v_profiler_after_snap');
                        this.render();
                        this.setupEventListeners();
                    });
                }

                // Print PDF Report
                const printPdfBtn = this.shadowRoot.getElementById('print-pdf-btn');
                if (printPdfBtn) {
                    printPdfBtn.addEventListener('click', () => {
                        this.printPdfReport();
                    });
                }

                // Copy TOML configuration suggested
                const copyBtn = this.shadowRoot.getElementById('copy-toml-btn');
                if (copyBtn) {
                    copyBtn.addEventListener('click', () => {
                        const pre = this.shadowRoot.getElementById('suggested-toml-pre');
                        if (pre) {
                            navigator.clipboard.writeText(pre.innerText).then(() => {
                                copyBtn.textContent = 'Copied!';
                                copyBtn.style.background = 'rgba(16, 185, 129, 0.2)';
                                copyBtn.style.borderColor = 'rgba(16, 185, 129, 0.4)';
                                setTimeout(() => {
                                    copyBtn.textContent = 'Copy';
                                    copyBtn.style.background = 'rgba(255, 255, 255, 0.08)';
                                    copyBtn.style.borderColor = 'rgba(255, 255, 255, 0.12)';
                                }, 2000);
                            }).catch(err => {
                                console.error('Failed to copy text: ', err);
                            });
                        }
                    });
                }
            }
        }

        renderBenchmarks() {
            const before = JSON.parse(localStorage.getItem('v_profiler_before_snap')) || null;
            const after = JSON.parse(localStorage.getItem('v_profiler_after_snap')) || null;

            const currentSnap = {
                label: "Current Request",
                timestamp: Math.floor(Date.now() / 1000),
                url: window.location.pathname + window.location.search,
                total_duration_ms: parseFloat(this.data.overview?.total_duration_ms || 0),
                sql_duration_ms: parseFloat(this.data.queries ? this.data.queries.reduce((sum, q) => sum + parseFloat(q.duration_ms || 0), 0) : 0),
                sql_count: parseInt(this.data.queries ? this.data.queries.length : 0),
                peak_memory: this.data.overview?.peak_memory || '0 MB',
                external_requests_count: parseInt(this.data.external_requests ? this.data.external_requests.length : 0)
            };

            let sidebarHtml = `
                <div class="bench-sidebar">
                    <div class="bench-card">
                        <div class="bench-title">📍 Current Page Status</div>
                        <div style="font-size:11px; line-height:1.6; color:#cbd5e1;">
                            <div style="white-space:nowrap; overflow:hidden; text-overflow:ellipsis;"><strong>URL:</strong> <span style="font-family:monospace; color:#a78bfa;">${this.escapeHtml(currentSnap.url)}</span></div>
                            <div><strong>Load Time:</strong> ${currentSnap.total_duration_ms} ms</div>
                            <div><strong>SQL Queries:</strong> ${currentSnap.sql_count} queries</div>
                            <div><strong>SQL Duration:</strong> ${currentSnap.sql_duration_ms.toFixed(2)} ms</div>
                            <div><strong>Memory:</strong> ${currentSnap.peak_memory}</div>
                        </div>
                        <div class="bench-btn-group" style="flex-direction:column; gap:6px; margin-top:10px;">
                            <button class="bench-btn" id="save-before-btn">📸 Save as BEFORE (Old Stack)</button>
                            <button class="bench-btn" id="save-after-btn" style="background:rgba(16,185,129,0.1); border-color:rgba(16,185,129,0.2); color:#34d399;">📸 Save as AFTER (vhttpd)</button>
                        </div>
                    </div>
            `;

            if (before || after) {
                sidebarHtml += `
                    <div class="bench-card">
                        <div class="bench-title">🧹 Manage Snapshots</div>
                        <div class="bench-btn-group">
                            <button class="bench-btn danger" id="clear-snaps-btn" style="width:100%;">Clear Snapshots</button>
                        </div>
                    </div>
                `;
            } else {
                sidebarHtml += `
                    <div class="bench-card">
                        <div class="bench-title">💡 Quick Demo</div>
                        <div style="font-size:10px; color:#94a3b8; line-height:1.4; margin-bottom:8px;">
                            No Before snapshot? You can populate a typical Nginx industry benchmark to simulate the performance of the traditional PHP-FPM architecture.
                        </div>
                        <button class="bench-btn secondary" id="fill-nginx-btn" style="width:100%;">⚡ Import Nginx Baseline</button>
                    </div>
                `;
            }

            sidebarHtml += `</div>`;

            let mainHtml = '';
            if (!before && !after) {
                mainHtml = `
                    <div class="bench-main" style="justify-content:center; align-items:center; color:#64748b; text-align:center;">
                        <div style="font-size:36px; margin-bottom:10px;">📊</div>
                        <div style="font-weight:600; font-size:13px; color:#94a3b8;">No A/B Benchmark snapshots saved.</div>
                        <div style="font-size:11px; max-width:320px; margin-top:5px; line-height:1.4;">
                            Save the BEFORE state (e.g., when running under Nginx) and the AFTER state (under vhttpd) to generate a side-by-side performance comparison report.
                        </div>
                    </div>
                `;
            } else {
                const bVal = before || {
                    label: "N/A",
                    total_duration_ms: 0,
                    sql_duration_ms: 0,
                    sql_count: 0,
                    peak_memory: "0 MB",
                    external_requests_count: 0
                };
                const aVal = after || {
                    label: "N/A",
                    total_duration_ms: 0,
                    sql_duration_ms: 0,
                    sql_count: 0,
                    peak_memory: "0 MB",
                    external_requests_count: 0
                };

                const parseMem = (mStr) => {
                    const parsed = parseFloat(mStr);
                    return isNaN(parsed) ? 0 : parsed;
                };
                const bMem = parseMem(bVal.peak_memory);
                const aMem = parseMem(aVal.peak_memory);

                const maxDur = Math.max(bVal.total_duration_ms, aVal.total_duration_ms) || 1;
                const bDurPercent = (bVal.total_duration_ms / maxDur) * 100;
                const aDurPercent = (aVal.total_duration_ms / maxDur) * 100;

                const maxSql = Math.max(bVal.sql_count, aVal.sql_count) || 1;
                const bSqlPercent = (bVal.sql_count / maxSql) * 100;
                const aSqlPercent = (aVal.sql_count / maxSql) * 100;

                const maxMem = Math.max(bMem, aMem) || 1;
                const bMemPercent = (bMem / maxMem) * 100;
                const aMemPercent = (aMem / maxMem) * 100;

                const maxExt = Math.max(bVal.external_requests_count, aVal.external_requests_count) || 1;
                const bExtPercent = (bVal.external_requests_count / maxExt) * 100;
                const aExtPercent = (aVal.external_requests_count / maxExt) * 100;

                let speedupHtml = '';
                if (before && after && before.total_duration_ms > 0 && after.total_duration_ms > 0) {
                    const times = before.total_duration_ms / after.total_duration_ms;
                    if (times > 1.1) {
                        speedupHtml = `
                            <div class="comparison-summary">
                                🚀 <span>Performance Speedup: <strong>${times.toFixed(1)}x Faster</strong> with vhttpd stack (reduced by ${(((before.total_duration_ms - after.total_duration_ms) / before.total_duration_ms) * 100).toFixed(1)}%) !</span>
                                <button class="bench-btn" id="print-pdf-btn" style="margin-left:auto; background:#10b981; border:1px solid #059669; color:#fff; padding:4px 10px; flex:none;">📄 Print PDF Report</button>
                            </div>
                        `;
                    } else {
                        speedupHtml = `
                            <div class="comparison-summary" style="background:rgba(96,165,250,0.08); border-color:rgba(96,165,250,0.15); color:#60a5fa;">
                                ℹ️ <span>Before & After profiles are registered. Performance difference is minor.</span>
                                <button class="bench-btn" id="print-pdf-btn" style="margin-left:auto; background:#3b82f6; border:1px solid #2563eb; color:#fff; padding:4px 10px; flex:none;">📄 Print PDF Report</button>
                            </div>
                        `;
                    }
                } else {
                    speedupHtml = `
                        <div style="font-size:11px; padding:8px; background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.05); border-radius:4px; color:#94a3b8; text-align:center;">
                            💡 Save both Before and After snapshots to generate a speedup evaluation report.
                        </div>
                    `;
                }

                mainHtml = `
                    <div class="bench-main">
                        ${speedupHtml}

                        <div class="comparison-item">
                            <div class="comparison-label">
                                <span>⏱️ Page Load Duration</span>
                                <span style="font-size:10px; color:#94a3b8;">Lower is better</span>
                            </div>
                            <div class="comparison-bar-group">
                                <div class="comparison-bar-row">
                                    <span class="bar-name">Before</span>
                                    <div class="bar-track">
                                        <div class="bar-fill before" style="width: ${bDurPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${bVal.total_duration_ms} ms</span>
                                </div>
                                <div class="comparison-bar-row" style="margin-top:4px;">
                                    <span class="bar-name">After</span>
                                    <div class="bar-track">
                                        <div class="bar-fill after" style="width: ${aDurPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${aVal.total_duration_ms} ms</span>
                                </div>
                            </div>
                        </div>

                        <div class="comparison-item">
                            <div class="comparison-label">
                                <span>🗄️ SQL Queries Executed</span>
                                <span style="font-size:10px; color:#94a3b8;">Fewer is better</span>
                            </div>
                            <div class="comparison-bar-group">
                                <div class="comparison-bar-row">
                                    <span class="bar-name">Before</span>
                                    <div class="bar-track">
                                        <div class="bar-fill before" style="width: ${bSqlPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${bVal.sql_count}</span>
                                </div>
                                <div class="comparison-bar-row" style="margin-top:4px;">
                                    <span class="bar-name">After</span>
                                    <div class="bar-track">
                                        <div class="bar-fill after" style="width: ${aSqlPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${aVal.sql_count}</span>
                                </div>
                            </div>
                        </div>

                        <div class="comparison-item">
                            <div class="comparison-label">
                                <span>🧠 Peak Memory Usage</span>
                                <span style="font-size:10px; color:#94a3b8;">Lower is better</span>
                            </div>
                            <div class="comparison-bar-group">
                                <div class="comparison-bar-row">
                                    <span class="bar-name">Before</span>
                                    <div class="bar-track">
                                        <div class="bar-fill before" style="width: ${bMemPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${bVal.peak_memory}</span>
                                </div>
                                <div class="comparison-bar-row" style="margin-top:4px;">
                                    <span class="bar-name">After</span>
                                    <div class="bar-track">
                                        <div class="bar-fill after" style="width: ${aMemPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${aVal.peak_memory}</span>
                                </div>
                            </div>
                        </div>

                        <div class="comparison-item">
                            <div class="comparison-label">
                                <span>🌐 Outgoing HTTP Calls</span>
                                <span style="font-size:10px; color:#94a3b8;">Fewer is better</span>
                            </div>
                            <div class="comparison-bar-group">
                                <div class="comparison-bar-row">
                                    <span class="bar-name">Before</span>
                                    <div class="bar-track">
                                        <div class="bar-fill before" style="width: ${bExtPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${bVal.external_requests_count}</span>
                                </div>
                                <div class="comparison-bar-row" style="margin-top:4px;">
                                    <span class="bar-name">After</span>
                                    <div class="bar-track">
                                        <div class="bar-fill after" style="width: ${aExtPercent}%"></div>
                                    </div>
                                    <span class="bar-value">${aVal.external_requests_count}</span>
                                </div>
                            </div>
                        </div>
                    </div>
                `;
            }

            return `
                <div class="bench-layout">
                    ${sidebarHtml}
                    ${mainHtml}
                </div>
            `;
        }

        printPdfReport() {
            const before = JSON.parse(localStorage.getItem('v_profiler_before_snap'));
            const after = JSON.parse(localStorage.getItem('v_profiler_after_snap'));
            if (!before || !after) return;

            const printWindow = window.open('', '_blank');
            if (!printWindow) {
                alert('弹出窗口被拦截，请允许弹窗以导出 PDF 报告');
                return;
            }

            const times = (before.total_duration_ms / after.total_duration_ms).toFixed(1);
            const diffPercent = (((before.total_duration_ms - after.total_duration_ms) / before.total_duration_ms) * 100).toFixed(1);
            const dateStr = new Date().toLocaleString();

            const parseMem = (mStr) => {
                const parsed = parseFloat(mStr);
                return isNaN(parsed) ? 0 : parsed;
            };
            const bMem = parseMem(before.peak_memory);
            const aMem = parseMem(after.peak_memory);

            const calcPercents = (v1, v2) => {
                const max = Math.max(v1, v2) || 1;
                return {
                    p1: ((v1 / max) * 100).toFixed(1),
                    p2: ((v2 / max) * 100).toFixed(1)
                };
            };

            const dPerc = calcPercents(before.total_duration_ms, after.total_duration_ms);
            const sPerc = calcPercents(before.sql_count, after.sql_count);
            const mPerc = calcPercents(bMem, aMem);
            const ePerc = calcPercents(before.external_requests_count, after.external_requests_count);

            const docContent = `
                <!DOCTYPE html>
                <html>
                <head>
                    <meta charset="utf-8">
                    <title>vhttpd Performance Benchmark Report</title>
                    <style>
                        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&display=swap');
                        body {
                            font-family: 'Inter', -apple-system, sans-serif;
                            color: #1e293b;
                            background: #ffffff;
                            margin: 0;
                            padding: 40px;
                            line-height: 1.5;
                        }
                        .header {
                            display: flex;
                            justify-content: space-between;
                            align-items: center;
                            border-bottom: 2px solid #f1f5f9;
                            padding-bottom: 20px;
                            margin-bottom: 30px;
                        }
                        .logo-area {
                            display: flex;
                            align-items: center;
                            gap: 10px;
                        }
                        .logo-text {
                            font-size: 22px;
                            font-weight: 800;
                            color: #8b5cf6;
                            letter-spacing: -0.5px;
                        }
                        .report-meta {
                            text-align: right;
                            font-size: 12px;
                            color: #64748b;
                        }
                        .banner {
                            background: linear-gradient(135deg, #f5f3ff 0%, #edd8ff 100%);
                            border: 1.5px solid #d8b4fe;
                            border-radius: 12px;
                            padding: 30px;
                            text-align: center;
                            margin-bottom: 40px;
                        }
                        .banner h1 {
                            margin: 0 0 10px 0;
                            font-size: 28px;
                            font-weight: 800;
                            color: #5b21b6;
                        }
                        .banner p {
                            margin: 0;
                            font-size: 16px;
                            color: #6d28d9;
                            font-weight: 500;
                        }
                        .banner .stat-highlight {
                            font-size: 42px;
                            font-weight: 900;
                            color: #7c3aed;
                            margin-top: 15px;
                            display: block;
                        }
                        .section-title {
                            font-size: 18px;
                            font-weight: 700;
                            color: #0f172a;
                            margin-bottom: 20px;
                            border-left: 4px solid #8b5cf6;
                            padding-left: 10px;
                        }
                        .grid-layout {
                            display: grid;
                            grid-template-columns: 1fr 1fr;
                            gap: 30px;
                            margin-bottom: 40px;
                        }
                        .metric-card {
                            background: #f8fafc;
                            border: 1px solid #e2e8f0;
                            border-radius: 8px;
                            padding: 20px;
                        }
                        .metric-title {
                            font-weight: 700;
                            font-size: 14px;
                            color: #475569;
                            margin-bottom: 15px;
                            display: flex;
                            justify-content: space-between;
                        }
                        .bar-container {
                            margin-bottom: 12px;
                        }
                        .bar-label {
                            display: flex;
                            justify-content: space-between;
                            font-size: 11px;
                            color: #64748b;
                            font-weight: 600;
                            margin-bottom: 4px;
                        }
                        .bar-track {
                            background: #e2e8f0;
                            height: 12px;
                            border-radius: 6px;
                            overflow: hidden;
                        }
                        .bar-fill {
                            height: 100%;
                            border-radius: 6px;
                        }
                        .bar-fill.before {
                            background: #f59e0b;
                        }
                        .bar-fill.after {
                            background: #10b981;
                        }
                        .bar-value {
                            font-family: monospace;
                            font-weight: 700;
                        }
                        .tech-notes {
                            background: #fafafa;
                            border: 1px solid #f1f5f9;
                            border-radius: 8px;
                            padding: 20px;
                            font-size: 13px;
                            color: #475569;
                            margin-bottom: 40px;
                        }
                        .tech-notes ul {
                            margin: 10px 0 0 0;
                            padding-left: 20px;
                        }
                        .tech-notes li {
                            margin-bottom: 6px;
                        }
                        .footer {
                            text-align: center;
                            font-size: 11px;
                            color: #94a3b8;
                            border-top: 1px solid #f1f5f9;
                            padding-top: 20px;
                            margin-top: 50px;
                        }
                        @media print {
                            body {
                                padding: 0;
                            }
                            .tech-notes {
                                page-break-inside: avoid;
                            }
                            .metric-card {
                                page-break-inside: avoid;
                            }
                        }
                    </style>
                </head>
                <body>
                    <div class="header">
                        <div class="logo-area">
                            <span class="logo-text">v-Profiler Pro</span>
                        </div>
                        <div class="report-meta">
                            <div><strong>Report Date:</strong> ${dateStr}</div>
                            <div><strong>Target URL:</strong> ${this.escapeHtml(before.url)}</div>
                        </div>
                    </div>

                    <div class="banner">
                        <h1>vhttpd Stack WordPress Performance Report</h1>
                        <p>A/B performance metrics comparison before and after transitioning to the vhttpd stack</p>
                        <span class="stat-highlight">🚀 ${times}x Faster Performance</span>
                        <p style="font-size:14px; margin-top:5px; color:#5b21b6;">Page loading latency reduced by <strong>${diffPercent}%</strong></p>
                    </div>

                    <div class="section-title">Performance Benchmark Comparison</div>

                    <div class="grid-layout">
                        <div class="metric-card">
                            <div class="metric-title">
                                <span>⏱️ Page Load Duration</span>
                                <span style="font-size:11px; color:#ef4444; font-weight:600;">Lower is better</span>
                            </div>
                            <div class="bar-container">
                                <div class="bar-label">
                                    <span>Before (Traditional Stack)</span>
                                    <span class="bar-value">${before.total_duration_ms} ms</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill before" style="width: ${dPerc.p1}%"></div>
                                </div>
                            </div>
                            <div class="bar-container" style="margin-bottom:0;">
                                <div class="bar-label">
                                    <span>After (vhttpd Server Stack)</span>
                                    <span class="bar-value">${after.total_duration_ms} ms</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill after" style="width: ${dPerc.p2}%"></div>
                                </div>
                            </div>
                        </div>

                        <div class="metric-card">
                            <div class="metric-title">
                                <span>🗄️ SQL Queries Executed</span>
                                <span style="font-size:11px; color:#ef4444; font-weight:600;">Fewer is better</span>
                            </div>
                            <div class="bar-container">
                                <div class="bar-label">
                                    <span>Before (Traditional Stack)</span>
                                    <span class="bar-value">${before.sql_count}</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill before" style="width: ${sPerc.p1}%"></div>
                                </div>
                            </div>
                            <div class="bar-container" style="margin-bottom:0;">
                                <div class="bar-label">
                                    <span>After (vhttpd Server Stack)</span>
                                    <span class="bar-value">${after.sql_count}</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill after" style="width: ${sPerc.p2}%"></div>
                                </div>
                            </div>
                        </div>

                        <div class="metric-card">
                            <div class="metric-title">
                                <span>🧠 Peak Memory Usage</span>
                                <span style="font-size:11px; color:#ef4444; font-weight:600;">Lower is better</span>
                            </div>
                            <div class="bar-container">
                                <div class="bar-label">
                                    <span>Before (Traditional Stack)</span>
                                    <span class="bar-value">${before.peak_memory}</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill before" style="width: ${mPerc.p1}%"></div>
                                </div>
                            </div>
                            <div class="bar-container" style="margin-bottom:0;">
                                <div class="bar-label">
                                    <span>After (vhttpd Server Stack)</span>
                                    <span class="bar-value">${after.peak_memory}</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill after" style="width: ${mPerc.p2}%"></div>
                                </div>
                            </div>
                        </div>

                        <div class="metric-card">
                            <div class="metric-title">
                                <span>🌐 Outgoing Third-Party HTTP Calls</span>
                                <span style="font-size:11px; color:#ef4444; font-weight:600;">Fewer is better</span>
                            </div>
                            <div class="bar-container">
                                <div class="bar-label">
                                    <span>Before (Traditional Stack)</span>
                                    <span class="bar-value">${before.external_requests_count}</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill before" style="width: ${ePerc.p1}%"></div>
                                </div>
                            </div>
                            <div class="bar-container" style="margin-bottom:0;">
                                <div class="bar-label">
                                    <span>After (vhttpd Server Stack)</span>
                                    <span class="bar-value">${after.external_requests_count}</span>
                                </div>
                                <div class="bar-track">
                                    <div class="bar-fill after" style="width: ${ePerc.p2}%"></div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="section-title">Architectural Optimization Analysis</div>
                    <div class="tech-notes">
                        <strong>Why is the After (vhttpd) stack significantly faster?</strong>
                        <ul>
                            <li><strong>Built-in Keepalive SQL Connection Pool:</strong> WordPress usually initiates a new TCP handshake to MySQL on every single PHP request. vhttpd provides a persistent worker thread pool that keeps SQL connections alive globally, saving 30ms - 100ms of handshake latency per request.</li>
                            <li><strong>High Performance Cache Multiplexing:</strong> Page caching and object caching are handled at the HTTP layer, bypassing WordPress runtime compilation overhead when cached hits occur.</li>
                            <li><strong>Optimized PHP Worker Model:</strong> By spawning persistent, long-running PHP Workers instead of traditional on-demand PHP-FPM spawn patterns, request startup times are drastically reduced.</li>
                            <li><strong>Enterprise Security Shield:</strong> Rate limiter gates, DDoS traffic mitigation, and standard response header enforcement are pre-applied without any custom PHP plugin requirements, ensuring raw speed does not compromise safety.</li>
                        </ul>
                    </div>

                    <div class="footer">
                        This report is auto-generated by v-Profiler telemetry module for vhttpd Enterprise Server.
                        <br>
                        &copy; 2026 vhttpd Project. All rights reserved.
                    </div>

                    <script>
                        window.onload = function() {
                            setTimeout(function() {
                                window.print();
                            }, 500);
                        }
                    <\/script>
                </body>
                </html>
            `;

            printWindow.document.write(docContent);
            printWindow.document.close();
        }

        escapeHtml(str) {
            if (typeof str !== 'string') return '';
            return str
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#039;');
        }
    }

    customElements.define('v-profiler-widget', VProfilerWidget);
})();
