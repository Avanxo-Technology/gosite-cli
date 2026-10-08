import json,sys,glob,os
def load(p):
    out=[]
    for l in open(p):
        l=l.strip()
        if l:
            try: out.append(json.loads(l))
            except: pass
    return out
rows=[]
for p in sorted(glob.glob(sys.argv[1]+'/*.json')):
    n=os.path.basename(p)[:-5]; ev=load(p); tot=cost=turns=0
    if '-claude-' in n:
        d=ev[-1] if ev else {}
        for v in d.get('modelUsage',{}).values():
            tot+=v['inputTokens']+v['outputTokens']+v['cacheReadInputTokens']+v['cacheCreationInputTokens']
        cost=d.get('total_cost_usd',0); turns=d.get('num_turns',0)
    elif '-opencode-' in n:
        for e in ev:
            if e.get('type')=='step_finish':
                pt=e.get('part',{}); t=pt.get('tokens',{}); c=t.get('cache',{})
                tot+=t.get('input',0)+t.get('output',0)+t.get('reasoning',0)+c.get('read',0)+c.get('write',0); cost+=pt.get('cost',0) or 0; turns+=1
    else:
        end=[e for e in ev if e.get('type')=='agent_end']
        for m in (end[-1]['messages'] if end else []):
            u=m.get('usage') if m.get('role')=='assistant' else None
            if u: tot+=u.get('totalTokens',0); cost+=u.get('cost',{}).get('total',0); turns+=1
    rows.append((n,tot,turns,cost))
print('| run | tokens | model calls | cost USD |\n|---|---:|---:|---:|')
for r in rows: print(f'| {r[0]} | {r[1]:,} | {r[2]} | {r[3]:.4f} |')
