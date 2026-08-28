#!/usr/bin/env python3
"""Gonka Network Bootstrap v1 validation, Genesis retrieval, and ENV rendering."""
from __future__ import annotations
import argparse, hashlib, json, os, re, socket, subprocess, sys, tempfile
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import urlopen
import jsonschema

SCHEMA_URI="https://gonka-dev.net/v1.bootstrap.schema.json"; MAX_DOCUMENT_BYTES=256*1024
NODE_ID_RE=re.compile(r"^[0-9a-f]{40}$"); CHAIN_ID_RE=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
class BootstrapError(ValueError):
 def __init__(self,stage,field,message): super().__init__(f"bootstrap validation failed stage={stage} field={field}: {message}")
def duplicates(pairs):
 out={}
 for key,value in pairs:
  if key in out: raise BootstrapError("parse",key,"duplicate key")
  out[key]=value
 return out
def load(path):
 try:data=Path(path).read_bytes()
 except OSError as error:raise BootstrapError("read",str(path),str(error)) from error
 if len(data)>MAX_DOCUMENT_BYTES:raise BootstrapError("size",str(path),"document exceeds limit")
 try:return json.loads(data.decode("utf-8","strict"),object_pairs_hook=duplicates)
 except UnicodeDecodeError as error:raise BootstrapError("parse",str(path),"invalid UTF-8") from error
 except json.JSONDecodeError as error:raise BootstrapError("parse",str(path),f"invalid JSON at line {error.lineno}") from error
def schema_path():return Path(__file__).resolve().parent.parent/"bootstrap"/"v1.bootstrap.schema.json"
def valid_url(value,field,schemes):
 p=urlsplit(value)
 try: port=p.port
 except ValueError as error:raise BootstrapError("semantics",field,"has an invalid port") from error
 if p.scheme not in schemes or not p.netloc or p.username or p.password or p.fragment or p.query or port==0:raise BootstrapError("semantics",field,"has an unsupported scheme or unsafe URL component")
 return p
def validate(doc):
 if not isinstance(doc,dict):raise BootstrapError("schema","$","must be an object")
 schema=load(schema_path())
 try:
  jsonschema.Draft202012Validator.check_schema(schema); errors=sorted(jsonschema.Draft202012Validator(schema).iter_errors(doc),key=lambda x:list(x.path))
 except jsonschema.SchemaError as error:raise BootstrapError("schema","schema","repository schema is invalid") from error
 if errors:
  e=errors[0];raise BootstrapError("schema",".".join(map(str,e.absolute_path)) or "$",e.message)
 if not CHAIN_ID_RE.fullmatch(doc["chain_id"]):raise BootstrapError("semantics","chain_id","contains unsafe characters")
 ids=set();rpcs=set();p2ps=set();apis=0
 for i,seed in enumerate(doc["seeds"]):
  pre=f"seeds[{i}]"
  if not NODE_ID_RE.fullmatch(seed["node_id"]):raise BootstrapError("semantics",pre+".node_id","must be 40 lowercase hexadecimal characters")
  valid_url(seed["rpc"],pre+".rpc",{"http","https"}); p=valid_url(seed["p2p"],pre+".p2p",{"tcp"})
  if p.port is None:raise BootstrapError("semantics",pre+".p2p","must have an explicit port")
  if seed["node_id"] in ids or seed["rpc"] in rpcs or seed["p2p"] in p2ps:raise BootstrapError("semantics",pre,"duplicate seed identity or endpoint")
  ids.add(seed["node_id"]);rpcs.add(seed["rpc"]);p2ps.add(seed["p2p"])
  if "api" in seed:valid_url(seed["api"],pre+".api",{"http","https"});apis+=1
 if not apis:raise BootstrapError("semantics","seeds","at least one seed must provide api")
 for i,b in enumerate(doc["brokers"]):
  if len(set(b["api_urls"])) != len(b["api_urls"]):raise BootstrapError("semantics",f"brokers[{i}].api_urls","contains duplicate endpoint")
  for j,v in enumerate(b["api_urls"]):valid_url(v,f"brokers[{i}].api_urls[{j}]",{"https"})
  if "access_url" in b:valid_url(b["access_url"],f"brokers[{i}].access_url",{"https"})
 return doc
def env(doc):
 first=next(seed for seed in doc["seeds"] if "api" in seed);rpcs=[]
 for seed in doc["seeds"]:
  if seed["rpc"] not in rpcs:rpcs.append(seed["rpc"])
 if len(rpcs)<2:raise BootstrapError("env","seeds","two distinct RPC URLs required")
 def quote(v):return "'"+v.replace("'","'\\\"'\\\"'")+"'"
 return "".join(f"export {k}={quote(v)}\n" for k,v in (("SEED_API_URL",first["api"]),("SEED_NODE_RPC_URL",first["rpc"]),("SEED_NODE_P2P_URL",first["p2p"]),("RPC_SERVER_URL_1",rpcs[0]),("RPC_SERVER_URL_2",rpcs[1]))).encode()
def genesis(seed,doc,out):
 result=subprocess.run([os.environ.get("INFERENCED","inferenced"),"download-genesis",seed["rpc"],str(out)],capture_output=True,text=True)
 if result.returncode:raise BootstrapError("genesis",seed["rpc"],"official download-genesis failed")
 data=out.read_bytes();digest=hashlib.sha256(data).hexdigest()
 try:chain=json.loads(data.decode("utf-8"),object_pairs_hook=duplicates).get("chain_id")
 except Exception as error:raise BootstrapError("genesis",seed["rpc"],"official Genesis output is not strict JSON") from error
 if digest!=doc["genesis"]["sha256"] or chain!=doc["chain_id"]:raise BootstrapError("genesis",seed["rpc"],"downloaded Genesis hash or chain ID does not match descriptor")
 return data
def online(doc):
 bad=[]; peer_sets={}
 for seed in doc["seeds"]:
  try:
   with urlopen(seed["rpc"].rstrip("/")+"/status",timeout=10) as r:status=json.load(r)
   if status.get("result",{}).get("node_info",{}).get("id")!=seed["node_id"]:raise BootstrapError("online",seed["rpc"],"/status node ID does not match descriptor")
   with tempfile.TemporaryDirectory() as temp:genesis(seed,doc,Path(temp)/"genesis.json")
   with urlopen(seed["rpc"].rstrip("/")+"/net_info",timeout=10) as r:net_info=json.load(r)
   peer_sets[seed["node_id"]]={item.get("node_info",{}).get("id") for item in net_info.get("result",{}).get("peers",[])}
   p=valid_url(seed["p2p"],"p2p",{"tcp"})
   with socket.create_connection((p.hostname,p.port),timeout=10):pass
   if "api" in seed:
    with urlopen(seed["api"].rstrip("/")+"/v1/participants",timeout=10):pass
  except Exception as error:bad.append(str(error))
 for seed in doc["seeds"]:
  if not any(seed["node_id"] in peers for node,peers in peer_sets.items() if node!=seed["node_id"]):bad.append(f"bootstrap validation failed stage=online field={seed['node_id']}: no other seed reports this node through /net_info")
 for number,broker in enumerate(doc["brokers"]):
  for endpoint in broker["api_urls"]:
   try:
    with urlopen(endpoint.rstrip("/")+"/v1/models",timeout=10):pass
   except Exception as error:bad.append(f"bootstrap validation failed stage=online field=brokers[{number}]: broker endpoint unavailable ({type(error).__name__})")
 if bad:raise BootstrapError("online","seeds","; ".join(bad[:3]))
 print(f"PASS online network bootstrap chain_id={doc['chain_id']} seeds={len(doc['seeds'])}")
def main(argv):
 parser=argparse.ArgumentParser();sub=parser.add_subparsers(dest="command",required=True)
 for name in ("verify","online","env"):p=sub.add_parser(name);p.add_argument("file",type=Path)
 p=sub.add_parser("stage");p.add_argument("file",type=Path);p.add_argument("destination",type=Path)
 p=sub.add_parser("render");p.add_argument("input",type=Path);p.add_argument("output",type=Path)
 a=parser.parse_args(argv)
 try:
  doc=validate(load(a.input if a.command=="render" else a.file))
  if a.command=="verify":print(f"PASS offline network bootstrap file={a.file} chain_id={doc['chain_id']} genesis_sha256={doc['genesis']['sha256']} seeds={len(doc['seeds'])}");print("Repository attestation and live RPC checks were not run.")
  elif a.command=="online":online(doc)
  elif a.command=="env":sys.stdout.buffer.write(env(doc))
  elif a.command=="render":a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_bytes((json.dumps(doc,sort_keys=True,separators=(",",":"))+"\n").encode())
  elif a.command=="stage":
   selected=None
   with tempfile.TemporaryDirectory() as temp:
    target=Path(temp)/"genesis.json"
    for seed in doc["seeds"]:
     try:genesis(seed,doc,target);selected=seed;break
     except BootstrapError:pass
    if not selected:raise BootstrapError("genesis","seeds","no RPC candidate produced matching Genesis")
    root=a.destination;root.mkdir(mode=0o700,parents=True,exist_ok=True);(root/"genesis.json").write_bytes(target.read_bytes());(root/"bootstrap.env").write_bytes(env(doc));(root/"genesis-seeds.txt").write_text("".join(f"{s['node_id']}@{urlsplit(s['p2p']).hostname}:{urlsplit(s['p2p']).port}\n" for s in doc['seeds']))
   print(f"PASS staged network bootstrap chain_id={doc['chain_id']} selected_rpc={selected['rpc']}")
  return 0
 except BootstrapError as error:print(error,file=sys.stderr);return 1
if __name__=="__main__":raise SystemExit(main(sys.argv[1:]))
