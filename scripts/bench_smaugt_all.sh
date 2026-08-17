#!/usr/bin/env bash
set -euo pipefail

# Reproducible wrapper around the repository's cycle-count benchmark.  NTESTS
# timestamps produce NTESTS-1 samples because speed_print uses adjacent RDTSCs.
CORE=${CORE:-0}
REPS=${REPS:-1000}
WARMUP=${WARMUP:-10}
if ! [[ $REPS =~ ^[0-9]+$ ]] || (( REPS < 1000 )); then
  echo "REPS must be an integer >= 1000" >&2; exit 2
fi
if ! [[ $WARMUP =~ ^[0-9]+$ ]] || (( WARMUP < 1 )); then
  echo "WARMUP must be a positive integer" >&2; exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAMP=$(date -u +%Y%m%d_%H%M%S)
OUT="$ROOT/benchmark_results/smaugt_$STAMP"
mkdir -p "$OUT"
BUILD_LOG="$OUT/build.log"
CORRECT_LOG="$OUT/correctness.log"
: >"$BUILD_LOG"; : >"$CORRECT_LOG"

{
  date -u
  uname -a
  command -v lscpu >/dev/null && lscpu
  gcc --version 2>&1 || true
  command -v clang >/dev/null && clang --version || true
  git -C "$ROOT" branch --show-current
  git -C "$ROOT" rev-parse HEAD
  git -C "$ROOT" status --short
} >"$OUT/environment.txt" 2>&1

AVX2=no
if command -v lscpu >/dev/null && lscpu | grep -qi avx2; then AVX2=yes; fi
AFFINITY="unavailable"
RUN=()
if command -v taskset >/dev/null && taskset -c "$CORE" true 2>/dev/null; then
  RUN=(taskset -c "$CORE"); AFFINITY="core $CORE"
fi

build_impl() {
  local dir=$1 kind=$2 flags
  flags="-O3 -fomit-frame-pointer -mtune=native -DNTESTS=$((REPS + 1)) -DNWARMUP=$WARMUP"
  [[ $kind == avx2 ]] && flags="-march=native $flags -mavx2 -mbmi2 -mpopcnt"
  {
    echo "=== $kind: make clean ==="
    make -C "$ROOT/$dir" clean
    echo "=== $kind: alternate repository speed benchmark build ==="
    make -C "$ROOT/$dir" speed CFLAGS="$flags" \
      'SOURCES_SPEED=$(SOURCESKECCAK) $(BENCHDIR)/speed.c $(BENCHDIR)/cpucycles.c $(BENCHDIR)/speed_print.c $(SRCDIR)/randombytes.c'
  } >>"$BUILD_LOG" 2>&1
}

run_one() {
  local dir=$1 mode=$2 scheme=$3 impl=$4 slug=$5
  local log="$OUT/$slug.log"
  if [[ $impl == AVX2 && $AVX2 != yes ]]; then
    echo "UNSUPPORTED: CPU does not advertise AVX2" | tee "$log" >>"$CORRECT_LOG"
    return
  fi
  echo "=== $scheme $impl ===" >>"$CORRECT_LOG"
  "${RUN[@]}" "$ROOT/$dir/smaug-t$mode-speed" >"$log" 2>&1
  grep '^CORRECTNESS:' "$log" | tee -a "$CORRECT_LOG"
}

build_impl reference_implementation ref
if [[ $AVX2 == yes ]]; then build_impl optimized_implementation/kem avx2
else echo "AVX2 runtime unsupported; optimized build skipped" >>"$BUILD_LOG"; fi

for spec in '1 SMAUG-T128 smaugt128' '3 SMAUG-T192 smaugt192' '5 SMAUG-T256 smaugt256'; do
  read -r mode scheme slug <<<"$spec"
  run_one reference_implementation "$mode" "$scheme" Ref "${slug}_ref"
  run_one optimized_implementation/kem "$mode" "$scheme" AVX2 "${slug}_avx2"
done

python3 - "$OUT" "$AFFINITY" "$AVX2" "$REPS" <<'PY'
import csv, math, os, platform, re, statistics, subprocess, sys
out, affinity, avx2, requested = sys.argv[1:]
rows=[]
mapping=[("SMAUG-T128","Ref","smaugt128_ref.log"),("SMAUG-T128","AVX2","smaugt128_avx2.log"),
         ("SMAUG-T192","Ref","smaugt192_ref.log"),("SMAUG-T192","AVX2","smaugt192_avx2.log"),
         ("SMAUG-T256","Ref","smaugt256_ref.log"),("SMAUG-T256","AVX2","smaugt256_avx2.log")]
names={"keygen_kem:":"KeyGen","encap:":"Encaps","decap:":"Decaps"}
with open(os.path.join(out,"raw_cycles.csv"),"w",newline="") as f:
 w=csv.writer(f); w.writerow(["scheme","implementation","operation","sample","cycles"])
 for scheme,impl,name in mapping:
  samples={v:[] for v in names.values()}; path=os.path.join(out,name)
  if os.path.exists(path):
   for line in open(path):
    m=re.match(r"RAW,(.*),(\d+),(\d+)$",line.rstrip())
    label=m.group(1).strip() if m else ""
    if m and label in names:
     op=names[label]; value=int(m.group(3)); samples[op].append(value)
     w.writerow([scheme,impl,op,m.group(2),value])
  stats={}
  for op,vals in samples.items():
   if vals: stats[op]=(round(statistics.median(vals)),statistics.mean(vals),min(vals),max(vals),statistics.pstdev(vals),len(vals))
  rows.append((scheme,impl,stats))

def med(stats,op): return stats.get(op,("UNSUPPORTED",))[0]
def kc(x): return "UNSUPPORTED" if not isinstance(x,int) else str(math.floor(x/1000+0.5))
with open(os.path.join(out,"summary.csv"),"w",newline="") as f:
 w=csv.writer(f); w.writerow(["scheme","implementation","keygen_cycles","encaps_cycles","decaps_cycles","keygen_kcycles","encaps_kcycles","decaps_kcycles"])
 for s,i,st in rows:
  vals=[med(st,x) for x in ("KeyGen","Encaps","Decaps")]; w.writerow([s,i,*vals,*(kc(x) for x in vals)])
with open(os.path.join(out,"statistics.csv"),"w",newline="") as f:
 w=csv.writer(f); w.writerow(["scheme","implementation","operation","samples","median","mean","min","max","stddev"])
 for s,i,st in rows:
  for op,v in st.items(): w.writerow([s,i,op,v[5],v[0],f"{v[1]:.2f}",v[2],v[3],f"{v[4]:.2f}"])

env=open(os.path.join(out,"environment.txt")).read()
cpu=re.search(r"Model name:\s*(.*)",env,re.I); arch=re.search(r"Architecture:\s*(.*)",env,re.I)
compiler=subprocess.run(["gcc","-dumpfullversion","-dumpversion"],text=True,capture_output=True).stdout.strip()
commit=subprocess.run(["git","rev-parse","HEAD"],cwd=os.path.dirname(os.path.dirname(out)),text=True,capture_output=True).stdout.strip()
d={(s,i):st for s,i,st in rows}
with open(os.path.join(out,"summary.md"),"w") as f:
 f.write("# SMAUG-T Benchmark\n\n## Environment\n\n")
 f.write(f"CPU: {cpu.group(1) if cpu else 'unknown'}\n\nCPU architecture: {arch.group(1) if arch else platform.machine()}\n\nOS: {platform.platform()}\n\nCompiler: gcc {compiler}\n\nCommit: {commit}\n\nCPU affinity: {affinity}\n\nAVX2: {avx2}\n\nRequested raw samples per operation: {requested}\n\n")
 f.write("## Correctness\n\n| Scheme | Ref | AVX2 |\n|---|---|---|\n")
 for s in ("SMAUG-T128","SMAUG-T192","SMAUG-T256"):
  f.write(f"| {s} | {'PASS' if d[(s,'Ref')] else 'FAIL'} | {'PASS' if d[(s,'AVX2')] else 'UNSUPPORTED'} |\n")
 f.write("\n## Median cycles\n\n| Scheme | Implementation | KeyGen | Encaps | Decaps |\n|---|---|---:|---:|---:|\n")
 for s,i,st in rows: f.write(f"| {s} | {i} | {med(st,'KeyGen')} | {med(st,'Encaps')} | {med(st,'Decaps')} |\n")
 f.write("\n## Table 7 values in kCycles\n\n| Scheme | Ref KG | Ref Enc | Ref Dec | AVX2 KG | AVX2 Enc | AVX2 Dec |\n|---|---:|---:|---:|---:|---:|---:|\n")
 for s in ("SMAUG-T128","SMAUG-T192","SMAUG-T256"):
  vals=[med(d[(s,i)],op) for i in ('Ref','AVX2') for op in ('KeyGen','Encaps','Decaps')]
  f.write("| "+s+" | "+" | ".join(kc(x) for x in vals)+" |\n")
 f.write("\n## AVX2 speedups\n\n| Scheme | KeyGen | Encaps | Decaps |\n|---|---:|---:|---:|\n")
 for s in ("SMAUG-T128","SMAUG-T192","SMAUG-T256"):
  vals=[]
  for op in ('KeyGen','Encaps','Decaps'):
   r,a=med(d[(s,'Ref')],op),med(d[(s,'AVX2')],op); vals.append(f"{r/a:.2f}x" if isinstance(a,int) else "UNSUPPORTED")
  f.write("| "+s+" | "+" | ".join(vals)+" |\n")
PY

echo "Results: $OUT"
