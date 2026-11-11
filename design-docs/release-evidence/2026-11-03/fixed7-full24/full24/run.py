from pathlib import Path
import subprocess,time,json,statistics,traceback,datetime
r=Path(__file__).resolve().parent
RETAINED_RSS_BUDGET_KIB=16*1024
def assess(result, rows, workload):
    if result['status'] != 'completed':
        raise ValueError('Workload did not complete successfully')
    if result['http_errors'] or result['paseo_errors']:
        raise ValueError('Workload reported request errors')
    if workload != 'paseo' and (not result['http_ok']):
        raise ValueError('No successful HTTP traffic')
    if workload != 'http' and (not result['paseo_ok']):
        raise ValueError('No successful Paseo traffic')
    load = [r for r in rows if r['phase'] == 'load']
    cool = [r for r in rows if r['phase'] == 'cooldown']
    if len(load) < 6 or len(cool) < 2:
        raise ValueError('Insufficient load/cooldown samples')
    baseline = statistics.median((r['runtime']['VmRSS'] for r in load[:3]))
    settled = statistics.median((r['runtime']['VmRSS'] for r in cool[-3:]))
    peak = max((r['runtime']['VmRSS'] for r in load))
    if settled > baseline + RETAINED_RSS_BUDGET_KIB:
        raise ValueError(f'Retained RSS grew more than 16 MiB: {baseline} -> {settled} KiB')
    if peak > 256 * 1024:
        raise ValueError(f'Load RSS exceeded 256 MiB: {peak} KiB')
    if max((r['runtime']['fd_count'] for r in load)) > load[0]['runtime']['fd_count'] + 8:
        raise ValueError('File descriptor growth exceeded the eight-FD budget')
    return {'baseline_rss_kib': baseline, 'settled_rss_kib': settled, 'max_load_rss_kib': peak, 'http_ok': result['http_ok'], 'paseo_ok': result['paseo_ok']}
def save(path,data):
 tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(data,indent=2));tmp.replace(path)
def analysis(final=False):
 rows=[json.loads(x) for x in (r/'samples.ndjson').read_text().splitlines()] if (r/'samples.ndjson').exists() else []
 groups={phase:[x for x in rows if x['phase']==phase] for phase in ['baseline','load','cooldown']}
 def window(g):
  return {k:statistics.median(x['runtime'][k] for x in g) for k in ['VmRSS','RssAnon','fd_count','Threads']} if g else None
 report={'status':'running','updated_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sample_count':len(rows),'phases':{p:{'sample_count':len(g),'first_60s':window(g[:6]),'last_60s':window(g[-6:])} for p,g in groups.items()},'load_hourly':[]}
 load=groups['load'];cool=groups['cooldown']
 for hour in range(24):
  g=[x for x in load if 600+hour*3600<=x['elapsed_seconds']<600+(hour+1)*3600]
  if g:report['load_hourly'].append({'hour':hour+1,'samples':len(g),**window(g)})
 if load:
  report['load_peak_rss_kib']=max(x['runtime']['VmRSS'] for x in load)
  report['load_growth_kib']=window(load[-6:])['VmRSS']-window(load[:6])['VmRSS']
 if load and cool:report['cool_vs_load_start_kib']=window(cool[-6:])['VmRSS']-window(load[:6])['VmRSS']
 if final:
  result=json.loads((r/'result.json').read_text());report['status']=result['status']
  report['counters']={k:result[k] for k in ['http_ok','http_errors','paseo_ok','paseo_errors']}
  try:
   report['assessment']=assess(result,rows,'mixed')
   assert all('oom_kill 0' in x['cgroup_memory_events'] and '\noom 0' in x['cgroup_memory_events'] for x in rows),'OOM observed'
   report['gate']='passed'
  except Exception as error:report.update(gate='failed',failure=str(error))
 save(r/'memory-analysis.json',report)
 return report
binary=str(r.parent/'package/vhttpd')
command=['/usr/bin/python3',str(r/'remote_soak.py'),'--binary',binary,'--observe-pid','9303','--workload','mixed','--signature-mode','isolated','--duration','87600']
p=subprocess.Popen(command)
try:
 while p.poll() is None:
  analysis();time.sleep(30)
 report=analysis(final=True)
 if p.returncode or report['gate']!='passed':raise RuntimeError('Full soak or final gates failed')
except BaseException as error:
 save(r/'controller-failure.json',{'failure':str(error),'traceback':traceback.format_exc()})
 raise
