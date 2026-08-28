#!/usr/bin/env python3
"""Focused conformance tests for the RPC-backed bootstrap contract."""
from __future__ import annotations
import json, subprocess, tempfile, unittest
from pathlib import Path
from jsonschema import Draft202012Validator
ROOT=Path(__file__).resolve().parent.parent; TOOL=ROOT/"scripts/network-bootstrap.py"; SCHEMA=ROOT/"bootstrap/v1.bootstrap.schema.json"; RELEASE=ROOT/"bootstrap/release"
def document():
 return {"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-fixture","genesis":{"sha256":"0"*64},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"http://one.example:8000/chain-rpc","p2p":"tcp://one.example:5000","api":"http://one.example:8000"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://two.example/chain-rpc","p2p":"tcp://two.example:5000"}],"brokers":[]}
class TestBootstrap(unittest.TestCase):
 def tool(self,*args):return subprocess.run(["python3",str(TOOL),*map(str,args)],text=True,capture_output=True)
 def write(self,d,name,value):p=d/name;p.write_text(json.dumps(value));return p
 def test_schema_three_documents_and_env_parity(self):
  Draft202012Validator.check_schema(json.loads(SCHEMA.read_text()))
  for name,chain,seeds in (("gonka-devnet-community.json","gonka-devnet-community",5),("gonka-mainnet.json","gonka-mainnet",2),("gonka-testnet.json","gonka-testnet",2)):
   doc=json.loads((RELEASE/name).read_text());self.assertEqual(doc["chain_id"],chain);self.assertEqual(len(doc["seeds"]),seeds);self.assertEqual(self.tool("verify",RELEASE/name).returncode,0);self.assertEqual(self.tool("env",RELEASE/name).stdout.encode(),(RELEASE/(name.removesuffix(".json")+".env")).read_bytes())
  community=json.loads((RELEASE/"gonka-devnet-community.json").read_text());self.assertEqual([seed["node_id"] for seed in community["seeds"]],["a78baa4988a9be991685080df4c232b1fdbe60ac","0f955d2e5ff3bdeabf04d91b5d590dc902aae4d0","ce4ff321a327263939a9f50fce2de988af95a5db","dda7f9dd24446c9e0b9fd6caac9a9d354dfdd651","1c62708ec56fe02d52c3ecedd388ebcc9ace55b4"])
  self.assertEqual(community["seeds"][0]["api"],"https://node0.gonka-dev.net");self.assertEqual(community["brokers"][0]["api_urls"],["https://api.gonka-dev.net"])
 def test_http_network_control_but_https_brokers(self):
  with tempfile.TemporaryDirectory() as t:
   d=Path(t);good=self.write(d,"good.json",document());self.assertEqual(self.tool("verify",good).returncode,0)
   bad=document();bad["brokers"]=[{"api_urls":["http://bad.example"]}];r=self.tool("verify",self.write(d,"bad.json",bad));self.assertNotEqual(r.returncode,0);self.assertIn("brokers",r.stderr)
   bad=document();bad["brokers"]=[{"api_urls":["https://broker.example","https://broker.example"]}];self.assertNotEqual(self.tool("verify",self.write(d,"duplicate-broker.json",bad)).returncode,0)
 def test_env_projection_and_rejections(self):
  with tempfile.TemporaryDirectory() as t:
   d=Path(t);p=self.write(d,"good.json",document());r=self.tool("env",p);self.assertEqual(r.returncode,0);self.assertIn("SEED_API_URL='http://one.example:8000'",r.stdout);self.assertIn("RPC_SERVER_URL_2='https://two.example/chain-rpc'",r.stdout)
   for key in ("rpc_servers","registration_apis","publisher","genesis_data"):
    bad=document();bad[key]=[];self.assertNotEqual(self.tool("verify",self.write(d,key+".json",bad)).returncode,0)
   bad=document();bad["seeds"][0]["p2p"]="tcp://one.example:70000";self.assertNotEqual(self.tool("verify",self.write(d,"port.json",bad)).returncode,0)
 def test_requires_api_two_seeds_and_safe_chain(self):
  with tempfile.TemporaryDirectory() as t:
   d=Path(t)
   for name,mutate in (("api",lambda x:[s.pop("api",None) for s in x["seeds"]]),("one",lambda x:x.__setitem__("seeds",x["seeds"][:1])),("chain",lambda x:x.__setitem__("chain_id","bad/path"))):
    bad=document();mutate(bad);self.assertNotEqual(self.tool("verify",self.write(d,name+".json",bad)).returncode,0)
 def test_pair_publication_retains_previous_pair(self):
  publisher=ROOT/"scripts/publish-network-bootstrap-pair.sh"
  with tempfile.TemporaryDirectory() as t:
   d=Path(t); json_file=RELEASE/"gonka-mainnet.json";env_file=RELEASE/"gonka-mainnet.env"; root=d/"public"
   first=subprocess.run([publisher,"--json",json_file,"--env",env_file,"--published-root",root],text=True,capture_output=True);self.assertEqual(first.returncode,0,first.stderr);previous=(root/"gonka-mainnet/bootstrap.json").read_bytes()
   bad=d/"bad.env";bad.write_text("broken\n");second=subprocess.run([publisher,"--json",json_file,"--env",bad,"--published-root",root],text=True,capture_output=True);self.assertNotEqual(second.returncode,0);self.assertEqual(previous,(root/"gonka-mainnet/bootstrap.json").read_bytes())
if __name__=="__main__":unittest.main()
