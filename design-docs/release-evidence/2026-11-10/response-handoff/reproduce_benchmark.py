"""Run the archived handoff benchmark against an already patched V tree."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile,os
p=argparse.ArgumentParser();p.add_argument('--vroot',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();root=a.vroot.resolve();source=Path(__file__).with_name('response_writer_allocation_test.v').read_bytes();test=root/'vlib/veb'/f'response_handoff_measure_{os.getpid()}_test.v';assert not test.exists();records=[]
try:
 test.write_bytes(source)
 with tempfile.TemporaryDirectory(prefix='veb-handoff-bench-') as work:
  binary=Path(work)/'bench';args=[str(root/'v'),'-cc','gcc' if os.uname().sysname=='Linux' else 'cc','-gc','boehm','-d','use_openssl','-d','response_transfer_bench','-o',str(binary),str(test)];subprocess.run(args,check=True)
  for i in range(3):
   r=subprocess.run([str(binary)],capture_output=True,text=True,check=True,timeout=30);records.append({'run':i+1,'stdout':r.stdout,'stderr':r.stderr});print(r.stdout,end='')
 a.output.write_text(json.dumps({'argv':args,'context_sha256':hashlib.sha256((root/'vlib/veb/context.v').read_bytes()).hexdigest(),'runs':records},indent=2)+'\n')
finally:
 if test.exists() and test.read_bytes()==source:test.unlink()
