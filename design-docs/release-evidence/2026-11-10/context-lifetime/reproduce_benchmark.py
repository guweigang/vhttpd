from pathlib import Path
import argparse,subprocess,os,tempfile,json,hashlib
p=argparse.ArgumentParser();p.add_argument('--vroot',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();root=a.vroot.resolve();source=Path(__file__).with_name('response_writer_state_allocation_test.v').read_bytes();target=root/'vlib/veb'/('writer_state_measure_'+str(os.getpid())+'_test.v');assert not target.exists()
try:
 target.write_bytes(source)
 with tempfile.TemporaryDirectory(prefix='veb-writer-measure-') as work:
  binary=Path(work)/'bench';cmd=[str(root/'v'),'-cc','gcc' if os.uname().sysname=='Linux' else 'cc','-gc','boehm','-d','use_openssl','-d','writer_state_bench','-o',str(binary),str(target)];subprocess.run(cmd,check=True);rows=[]
  for n,reverse in enumerate(['0','1','0'],1):
   env=os.environ.copy();env['WRITER_BENCH_REVERSE']=reverse;r=subprocess.run([str(binary)],env=env,capture_output=True,text=True,timeout=30,check=True);rows.append({'run':n,'reverse':reverse,'stdout':r.stdout,'stderr':r.stderr});print(r.stdout,end='')
  a.output.write_text(json.dumps({'argv':cmd,'source_sha256':hashlib.sha256((root/'vlib/veb/veb_fasthttp.v').read_bytes()).hexdigest(),'runs':rows},indent=2)+'\n')
finally:
 if target.exists() and target.read_bytes()==source:target.unlink()
