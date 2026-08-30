#!/bin/bash
# Downloads the free ("name your own price") files of one itch.io asset page.
set -e
PAGE="$1"; OUT="$2"; mkdir -p "$OUT"
JAR=$(mktemp)
curl -sL -c "$JAR" -b "$JAR" "$PAGE/purchase" -o /tmp/p.html
CSRF=$(grep -oE 'name="csrf_token" value="[^"]+"' /tmp/p.html | head -1 | sed 's/.*value="//;s/"$//')
DL=$(curl -s -b "$JAR" -c "$JAR" -X POST "$PAGE/download_url" -H "Content-Type: application/json" \
     -H "X-Requested-With: XMLHttpRequest" --data "{\"csrf_token\":\"$CSRF\"}" \
     | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
curl -sL -b "$JAR" -c "$JAR" "$DL" -o /tmp/d.html
CSRF2=$(grep -oE 'name="csrf_token" value="[^"]+"' /tmp/d.html | head -1 | sed 's/.*value="//;s/"$//')
python3 - "$DL" "$CSRF2" "$JAR" "$OUT" <<'PY'
import sys,re,json,subprocess,html
dl,csrf,jar,out=sys.argv[1:5]
page=open('/tmp/d.html',encoding='utf-8',errors='replace').read()
ids=re.findall(r'data-upload_id="(\d+)"',page) or re.findall(r'upload_list_(\d+)',page)
names=re.findall(r'title="([^"]+)"[^>]*>\s*[^<]*</strong>',page)
print("uploads:",ids)
base=dl.split('/download/')[0]
for uid in dict.fromkeys(ids):
    r=subprocess.run(['curl','-s','-b',jar,'-c',jar,'-X','POST',
        f'{base}/file/{uid}?after_download_lightbox=true',
        '-H','Content-Type: application/json','-H','X-Requested-With: XMLHttpRequest',
        '--data',json.dumps({"csrf_token":csrf})],capture_output=True,text=True)
    try: url=json.loads(r.stdout)["url"]
    except Exception: print("  no url for",uid,r.stdout[:200]); continue
    fn=html.unescape(url.split('/')[-1].split('?')[0])
    subprocess.run(['curl','-sL','-b',jar,'-c',jar,url,'-o',f'{out}/{fn}'])
    print("  saved",fn)
PY
