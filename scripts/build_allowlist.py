#!/usr/bin/env python3
"""Build universe/allowlist.json: stock tokens we can buy safely.

A token is allowlisted only if
  1. it is one of the 194 canonical Robinhood tokens in ../universe/tokens.txt,
  2. Chainlink publishes a Robinhood <TICKER>/USD feed on Robinhood Chain,
  3. the token address is a Robinhood stock-token beacon proxy (runtime codehash
     matches NVDA's), found via Dexscreener and fingerprinted on chain.
For each we also record the deepest Uniswap v3 pools vs USDG and WETH.
"""
import json, re, sys, time, urllib.request, hashlib, subprocess, os
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.dirname(HERE)
RPC='https://rpc.mainnet.chain.robinhood.com'
FINGERPRINT='0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630'
WETH='0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73'.lower()
USDG='0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168'.lower()
V3_FACTORY='0x1f7d7550B1b028f7571E69A784071F0205FD2EfA'.lower()
def rpc(method, params):
    req=urllib.request.Request(RPC, data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), headers={'content-type':'application/json','user-agent':'signed-pot/1'})
    return json.loads(urllib.request.urlopen(req,timeout=30).read())['result']
def keccak(hexcode):
    return subprocess.check_output([os.path.expanduser('~/.foundry/bin/cast'),'keccak',hexcode]).decode().strip()
def call(to, sig):
    return subprocess.check_output([os.path.expanduser('~/.foundry/bin/cast'),'call',to,sig,'--rpc-url',RPC]).decode().strip()
def get(url):
    for i in range(5):
        try: return json.loads(urllib.request.urlopen(urllib.request.Request(url,headers={'user-agent':'signed-pot/1'}),timeout=30).read())
        except Exception as e:
            time.sleep(2+i*2)
    raise SystemExit('fetch failed '+url)

universe=set(open(os.path.join(ROOT,'..','universe','tokens.txt')).read().split())
feeds=json.load(open(os.path.join(ROOT,'_raw','chainlink-feeds.json')))
stockfeeds={}
for f in feeds:
    m=re.match(r'Robinhood ([A-Z]+)\s*(?:/|-)\s*USD$', f['name'])
    if m: stockfeeds[m.group(1)]={'feed':f['proxyAddress'],'decimals':f['decimals'],'heartbeat':f['heartbeat']}
ethusd=[f for f in feeds if f['name']=='ETH / USD'][0]
usdgusd=[f for f in feeds if f['name']=='USDG / USD'][0]
tickers=sorted(t for t in stockfeeds if t in universe)
print('feed-backed Robinhood tokens:',len(tickers),tickers, file=sys.stderr)
print('skipped (feed but not in universe):',sorted(set(stockfeeds)-set(tickers)), file=sys.stderr)

out={'chainId':4663,'fingerprint':FINGERPRINT,'weth':WETH,'usdg':USDG,'v3Factory':V3_FACTORY,
     'ethUsdFeed':ethusd['proxyAddress'],'usdgUsdFeed':usdgusd['proxyAddress'],'stocks':[]}
allowlist_path=os.path.join(ROOT,'universe','allowlist.json')
cached={}
if os.path.exists(allowlist_path):
    cached={s['ticker']:s for s in json.load(open(allowlist_path)).get('stocks',[])}
codecache={}
def is_stock(addr):
    a=addr.lower()
    if a not in codecache:
        code=rpc('eth_getCode',[a,'latest'])
        codecache[a]= (code!='0x' and keccak(code)==FINGERPRINT)
    return codecache[a]

def pools_for(pairs, token):
    res=[]
    for p in pairs:
        if p.get('chainId')!='robinhood' or p.get('dexId')!='uniswap' or 'v3' not in (p.get('labels') or []): continue
        b,q=p['baseToken']['address'].lower(), p['quoteToken']['address'].lower()
        if token not in (b,q): continue
        other=q if b==token else b
        if other not in (WETH,USDG): continue
        res.append({'pool':p['pairAddress'],'other':'USDG' if other==USDG else 'WETH','liqUsd':(p.get('liquidity') or {}).get('usd') or 0,'vol24':(p.get('volume') or {}).get('h24') or 0})
    return res

for t in tickers:
    if t in cached:
        out['stocks'].append(cached[t])
        print(t,cached[t]['address'],'cached', file=sys.stderr)
        continue
    d=get('https://api.dexscreener.com/latest/dex/search?q='+t)
    pairs=[p for p in d.get('pairs',[]) if p.get('chainId')=='robinhood']
    cands=set()
    for p in pairs:
        for side in ('baseToken','quoteToken'):
            if p[side]['symbol'].upper()==t: cands.add(p[side]['address'].lower())
    real=[c for c in cands if is_stock(c)]
    if len(real)!=1:
        print('!!',t,'candidates',len(cands),'real',real, file=sys.stderr); 
        if not real: continue
    addr=real[0]
    pools=pools_for(pairs,addr)
    for p in pools:
        p['fee']=int(call(p['pool'],'fee()(uint24)').split()[0])
        p['token0']=call(p['pool'],'token0()(address)').lower()
    best={}
    for p in sorted(pools,key=lambda x:-x['liqUsd']):
        best.setdefault(p['other'],p)
    name=call(addr,'name()(string)')
    out['stocks'].append({'ticker':t,'address':addr,'name':name.strip('"'),**stockfeeds[t],'poolUsdg':best.get('USDG'),'poolWeth':best.get('WETH'),'fakes':len(cands)-1})
    print(t,addr,'USDG',best.get('USDG',{}).get('liqUsd'),'WETH',best.get('WETH',{}).get('liqUsd'),'fakes',len(cands)-1, file=sys.stderr)
    time.sleep(0.4)

# WETH/USDG pool
d=get('https://api.dexscreener.com/latest/dex/search?q=USDG')
wp=[p for p in pools_for([p for p in d.get('pairs',[]) if p.get('chainId')=='robinhood'], WETH) if p['other']=='USDG']
wp=sorted(wp,key=lambda x:-x['liqUsd'])
for p in wp[:3]:
    p['fee']=int(call(p['pool'],'fee()(uint24)').split()[0]); p['token0']=call(p['pool'],'token0()(address)').lower()
out['wethUsdgPools']=wp[:3]
print('WETH/USDG pools',wp[:3], file=sys.stderr)
json.dump(out,open(allowlist_path,'w'),indent=1)
print('wrote',len(out['stocks']),'stocks', file=sys.stderr)
