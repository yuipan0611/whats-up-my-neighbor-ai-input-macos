"""Small real-model acceptance fixture, not a general quality benchmark."""
import importlib.util
import json
from pathlib import Path
import sys
import time
spec=importlib.util.spec_from_file_location('office_app',Path(__file__).with_name('office.py'))
app=importlib.util.module_from_spec(spec);spec.loader.exec_module(app)
model=app.Ollama(sys.argv[1] if len(sys.argv)>1 else 'gemma3:1b')
check=lambda:None
progress=lambda n:None
cases=[
('幫我列出收件匣有哪些檔案。','','list_files'),
('請把選取的筆記整理成三點摘要，保留日期、人名與待辦。','測試筆記.md','summarize'),
('幫我寫一段給自己的工作鼓勵，50字以內。','','write'),
('幫我整理這份筆記。','','clarify'),
('幫我上網查今天的台灣新聞，整理來源連結。','','external'),
('幫我研究2026年各家VPS價格，寫比較報告。','','external'),
('請替貓咪寫一則簡短的開工問候。','','write'),
('找近期Gemma新版本，附官方連結。','','external'),
('我剛剛的任務目前怎麼樣了？','','status'),
]
report={'model':model.health(),'routing':[]}
for prompt,source,expected in cases:
    query=json.dumps({'交辦':prompt,'已選來源':source,'收件匣檔名':['測試筆記.md']},ensure_ascii=False)
    raw,metrics=model.generate(app.PLANNER,query,check,progress,app.PLAN_SCHEMA,128)
    plan=json.loads(raw)
    row={'prompt':prompt,'expected':expected,'plan':plan,'passed':plan['action']==expected,'metrics':metrics}
    report['routing'].append(row)
    print(json.dumps(row,ensure_ascii=False),flush=True)
text='2026年10月21日會議筆記：小林負責整理需求，10月25日交初稿。小陳負責測試，預算上限是1200元。目前還沒決定是否購買新主機，先測試現有VPS。'
query=json.dumps({'交辦':'整理成三個繁體中文重點，保留人名、日期、金額及尚未決定的事。','來源檔名':'測試筆記.md','來源全文':text},ensure_ascii=False)
result,metrics=model.generate(app.WRITER,query,check,progress)
report['summary']={'source':text,'result':result,'metrics':metrics,'required_facts_present':all(x in result for x in ['小林','小陳','1200','10月25','需求']) and ('未' in result or '不' in result)}
print(json.dumps(report['summary'],ensure_ascii=False),flush=True)
Path('benchmark-'+model.model.replace(':','-')+'.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('REPORT_SAVED',flush=True)
