#!/usr/bin/env python3
"""Reproduzierbare Laufzeiten; stdout ist JSON, alle Eingaben sind synthetisch/Fixtures."""
import argparse,json,pathlib,statistics,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--repo',type=pathlib.Path,default=pathlib.Path(__file__).resolve().parents[1]);p.add_argument('--runs',type=int,default=5);a=p.parse_args();root=a.repo.resolve()
setup='set -o pipefail; source lib/pipeline.sh; rtf_to_html() { if [ "$(uname -s)" = Darwin ]; then textutil -convert html -format rtf -stdin -stdout; else rtf_fix_escaped_newlines | pandoc -f rtf -t html; fi; }; '
def measure(cmd,data):
    times=[]
    for _ in range(a.runs):
        start=time.perf_counter();r=subprocess.run(cmd,input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=root,timeout=60);times.append((time.perf_counter()-start)*1000)
        assert r.returncode==0,r.stderr
    return {'median_ms':round(statistics.median(times),2),'samples_ms':[round(t,2) for t in times]},r.stdout
cases={'article':(root/'tests/fixtures/safari-article.html').read_bytes(),'word':(root/'tests/fixtures/word-rtf.rtf').read_bytes(),'code':(root/'tests/fixtures/claude-desktop-codeblock.html').read_bytes(),'large':b'<p>Text <b>bold</b> and <code>x\\y</code>.</p>'*10000}
cases['word_table'] = b'<table style="mso-table-layout-alt:fixed"><tr><th>Name</th><th>Text</th></tr><tr><td>Entry</td><td><p>First</p><p>Second</p></td></tr></table>'*20
results={'platform':subprocess.check_output(['uname','-sm'],text=True).strip(),'pandoc':subprocess.check_output(['pandoc','--version'],text=True).splitlines()[0],'runs':a.runs,'cases':{}}
results['startup_help'],_=measure(['bash','bin/md-clip','--help'],b'')
results['startup_version'],_=measure(['bash','bin/md-clip','--version'],b'')
for name,data in cases.items():
    result={'bytes':len(data)}
    result['pipeline'],_=measure(['bash','-c',setup+('convert_rtf' if name=='word' else 'convert_html')],data)
    stages=['rtf_to_html','flatten_layout_tables','unwrap_list_paragraphs'] if name=='word' else ['preprocess_claude_desktop','preprocess_google_classroom']
    stages+=['clean_html','fill_empty_html_links']
    if 'inline_table_cells()' in (root/'lib/pipeline.sh').read_text(): stages+=['inline_table_cells']
    stages+=['run_pandoc','tidy_markdown','require_nonempty_markdown']
    result['stages']={}
    for stage in stages: result['stages'][stage],data=measure(['bash','-c',setup+stage],data)
    results['cases'][name]=result
print(json.dumps(results,indent=2))
