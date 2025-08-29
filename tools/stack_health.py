#!/usr/bin/env python3
# stack_health.py — Verify homelab stack on k3s
# - No external deps; uses subprocess + stdlib HTTP
# - Checks: kubeconfig, API /readyz, node Ready + IP, core kube-system pods,
#   ArgoCD, Grafana/Prometheus, Loki/Promtail, whoami Ingress.
# Usage:
#   python3 stack_health.py
#   python3 stack_health.py --ip 192.168.2.60 --argocd argocd.pizza --grafana grafana.pizza --whoami whoami.pizza
#   python3 stack_health.py --https   # also probe HTTPS endpoints (self-signed allowed)

import argparse
import json
import os
import socket
import ssl
import subprocess
import sys
import time
from http.client import HTTPConnection, HTTPSConnection

GREEN = "\x1b[32m"
RED = "\x1b[31m"
YELLOW = "\x1b[33m"
CYAN = "\x1b[36m"
RESET = "\x1b[0m"
CHECK = "✅"
CROSS = "❌"
WARN  = "⚠️ "

def sh(cmd, timeout=20):
    """Run a shell command and return (rc, stdout, stderr)."""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True, text=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        return 124, "", f"timeout after {timeout}s"
    return p.returncode, out.strip(), err.strip()

def have(cmd):
    return shutil.which(cmd) is not None

def ok(msg):    print(f"{GREEN}{CHECK} {msg}{RESET}")
def fail(msg):  print(f"{RED}{CROSS} {msg}{RESET}")
def warn(msg):  print(f"{YELLOW}{WARN} {msg}{RESET}")
def info(msg):  print(f"{CYAN}{msg}{RESET}")

# avoid import if not needed
import shutil  # for which

def kubectl_json(args, kubeconfig):
    rc, out, err = sh(f"KUBECONFIG='{kubeconfig}' kubectl {args} -o json", timeout=40)
    if rc != 0:
        raise RuntimeError(f"kubectl {args} failed: {err or out}")
    return json.loads(out)

def http_probe(ip, host, scheme="http", path="/", timeout=6):
    """Send GET to IP with Host header set to host; return (ok, status, reason)."""
    try:
        if scheme == "https":
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            conn = HTTPSConnection(ip, 443, timeout=timeout, context=ctx)
        else:
            conn = HTTPConnection(ip, 80, timeout=timeout)
        conn.request("GET", path, headers={"Host": host, "User-Agent": "stack-health/1.0"})
        resp = conn.getresponse()
        data = resp.read(2000)  # small peek
        conn.close()
        # Consider anything <500 as "service reachable"
        okish = 100 <= resp.status < 500
        return okish, resp.status, resp.reason, data.decode("utf-8", errors="ignore")
    except Exception as e:
        return False, 0, str(e), ""

def pod_ready(pod):
    try:
        if pod.get("status", {}).get("phase") != "Running":
            return False
        cs = pod.get("status", {}).get("containerStatuses") or []
        return all(c.get("ready") for c in cs) and len(cs) > 0
    except Exception:
        return False

def main():
    parser = argparse.ArgumentParser(description="Verify homelab stack on k3s")
    parser.add_argument("--kubeconfig", default=os.environ.get("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml"),
                        help="Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)")
    parser.add_argument("--ip", default="192.168.2.60", help="Node/Ingress IP to probe (default: 192.168.2.60)")
    parser.add_argument("--argocd", default="argocd.pizza", help="Argo CD FQDN")
    parser.add_argument("--grafana", default="grafana.pizza", help="Grafana FQDN")
    parser.add_argument("--whoami", default="whoami.pizza", help="whoami FQDN")
    parser.add_argument("--https", action="store_true", help="Also probe HTTPS endpoints (insecure, accepts self-signed)")
    args = parser.parse_args()

    results = []
    passed = 0
    failed = 0
    warned = 0

    print()
    info("=== Kubeconfig & API ===")

    # kubeconfig present
    if os.path.isfile(args.kubeconfig):
        ok(f"kubeconfig found at {args.kubeconfig}")
        with open(args.kubeconfig, "r", encoding="utf-8", errors="ignore") as f:
            cfg = f.read()
        server_line = next((l for l in cfg.splitlines() if "server: " in l), "")
        if "127.0.0.1:6443" in server_line:
            warn("kubeconfig still points to https://127.0.0.1:6443 (will still try using it)")
            warned += 1
        else:
            ok(f"kubeconfig server: {server_line.strip() or '<unknown>'}")
    else:
        fail(f"kubeconfig missing: {args.kubeconfig}")
        failed += 1
        print("\nPlease run:")
        print(f"  sudo sed -i 's#https://127\\.0\\.0\\.1:6443#https://{args.ip}:6443#' {args.kubeconfig}")
        print()
        # continue anyway; kubectl will fail below

    # API /readyz
    try:
        rc, out, err = sh(f"KUBECONFIG='{args.kubeconfig}' kubectl get --raw='/readyz' 2>/dev/null")
        if rc == 0 and "ok" in out.lower():
            ok("API /readyz: OK")
            passed += 1
        else:
            fail(f"API /readyz: not ready ({err or out})")
            failed += 1
    except Exception as e:
        fail(f"API /readyz: error ({e})")
        failed += 1

    print()
    info("=== Node health ===")
    node_json = None
    try:
        node_json = kubectl_json("get nodes", args.kubeconfig)
        items = node_json.get("items", [])
        if not items:
            fail("No nodes returned by API")
            failed += 1
        else:
            node = items[0]
            name = node["metadata"]["name"]
            addresses = {a["type"]: a["address"] for a in node["status"]["addresses"]}
            internal_ip = addresses.get("InternalIP", "<missing>")
            ready = False
            for cond in node.get("status", {}).get("conditions", []):
                if cond.get("type") == "Ready":
                    ready = cond.get("status") == "True"
            if ready:
                ok(f"Node {name} Ready=True")
                passed += 1
            else:
                fail(f"Node {name} not Ready")
                failed += 1
            if internal_ip == args.ip:
                ok(f"Node InternalIP={internal_ip} (expected)")
                passed += 1
            else:
                fail(f"Node InternalIP={internal_ip} (expected {args.ip})")
                failed += 1
    except Exception as e:
        fail(f"kubectl get nodes failed: {e}")
        failed += 1

    print()
    info("=== Core kube-system pods ===")
    core_ok = True
    try:
        sys_pods = kubectl_json("-n kube-system get pods", args.kubeconfig).get("items", [])
        need = {
            "coredns": False,
            "traefik": False,
            "metrics-server": False,
            "local-path-provisioner": False,
        }
        for p in sys_pods:
            name = p["metadata"]["name"]
            for key in list(need.keys()):
                if name.startswith(key) and pod_ready(p):
                    need[key] = True
        for comp, is_ok in need.items():
            if is_ok:
                ok(f"{comp} Running/Ready")
                passed += 1
            else:
                core_ok = False
                fail(f"{comp} not Ready")
                failed += 1
    except Exception as e:
        fail(f"Failed to read kube-system pods: {e}")
        failed += 1

    print()
    info("=== Namespaces present ===")
    for ns in ["argocd", "monitoring", "logging", "default"]:
        try:
            rc, _, _ = sh(f"KUBECONFIG='{args.kubeconfig}' kubectl get ns {ns}")
            if rc == 0:
                ok(f"Namespace {ns} exists")
                passed += 1
            else:
                warn(f"Namespace {ns} missing (may be expected if not installed)")
                warned += 1
        except Exception:
            warn(f"Namespace {ns} check failed")
            warned += 1

    print()
    info("=== Argo CD ===")
    try:
        # deployment
        rc, out, err = sh(f"KUBECONFIG='{args.kubeconfig}' kubectl -n argocd get deploy argocd-server -o json")
        if rc == 0:
            d = json.loads(out)
            avail = d.get("status", {}).get("availableReplicas", 0)
            if avail and int(avail) > 0:
                ok("argocd-server deployment Available")
                passed += 1
            else:
                fail("argocd-server deployment not Available")
                failed += 1
        else:
            fail(f"argocd-server deployment not found ({err})")
            failed += 1
        # ingress probe
        alive, code, reason, _ = http_probe(args.ip, args.argocd, "http", "/")
        if alive:
            ok(f"HTTP probe argocd ({args.argocd}) -> {code} {reason}")
            passed += 1
        else:
            fail(f"HTTP probe argocd failed: {reason}")
            failed += 1
        if args.https:
            alive, code, reason, _ = http_probe(args.ip, args.argocd, "https", "/")
            if alive:
                ok(f"HTTPS probe argocd ({args.argocd}) -> {code} {reason}")
                passed += 1
            else:
                fail(f"HTTPS probe argocd failed: {reason}")
                failed += 1
    except Exception as e:
        fail(f"ArgoCD check error: {e}")
        failed += 1

    print()
    info("=== Grafana / Prometheus (kube-prometheus-stack) ===")
    try:
        # grafana deployment
        rc, out, err = sh(f"KUBECONFIG='{args.kubeconfig}' kubectl -n monitoring get deploy kube-prometheus-stack-grafana -o json")
        if rc == 0:
            d = json.loads(out)
            avail = d.get("status", {}).get("availableReplicas", 0)
            if avail and int(avail) > 0:
                ok("Grafana deployment Available")
                passed += 1
            else:
                fail("Grafana deployment not Available")
                failed += 1
        else:
            fail(f"Grafana deployment not found ({err})")
            failed += 1

        # operator pod status (helps catch ContainerCreating)
        rc, out, _ = sh(f"KUBECONFIG='{args.kubeconfig}' kubectl -n monitoring get deploy kube-prometheus-stack-operator -o json")
        if rc == 0:
            d = json.loads(out)
            avail = d.get("status", {}).get("availableReplicas", 0)
            if avail and int(avail) > 0:
                ok("Prometheus Operator Available")
                passed += 1
            else:
                warn("Prometheus Operator not Available yet")
                warned += 1
        else:
            warn("Prometheus Operator deployment not found")
            warned += 1

        # ingress probe
        alive, code, reason, body = http_probe(args.ip, args.grafana, "http", "/")
        if alive:
            ok(f"HTTP probe grafana ({args.grafana}) -> {code} {reason}")
            passed += 1
        else:
            fail(f"HTTP probe grafana failed: {reason}")
            failed += 1
        if args.https:
            alive, code, reason, _ = http_probe(args.ip, args.grafana, "https", "/")
            if alive:
                ok(f"HTTPS probe grafana ({args.grafana}) -> {code} {reason}")
                passed += 1
            else:
                fail(f"HTTPS probe grafana failed: {reason}")
                failed += 1
    except Exception as e:
        fail(f"Monitoring check error: {e}")
        failed += 1

    print()
    info("=== Loki / Promtail ===")
    try:
        pods = kubectl_json("-n logging get pods", args.kubeconfig).get("items", [])
        has_loki = any(p["metadata"]["name"].startswith("loki") and pod_ready(p) for p in pods)
        has_promtail = any("promtail" in p["metadata"]["name"] and pod_ready(p) for p in pods)
        if has_loki:
            ok("Loki pod Running/Ready")
            passed += 1
        else:
            warn("Loki not Ready")
            warned += 1
        if has_promtail:
            ok("Promtail pod Running/Ready")
            passed += 1
        else:
            warn("Promtail not Ready")
            warned += 1
    except Exception as e:
        warn(f"Loki/Promtail check error: {e}")
        warned += 1

    print()
    info("=== Demo app: whoami ===")
    try:
        # svc present?
        rc, _, _ = sh(f"KUBECONFIG='{args.kubeconfig}' kubectl -n default get svc whoami")
        if rc == 0:
            ok("whoami Service exists")
            passed += 1
        else:
            warn("whoami Service missing")
            warned += 1
        alive, code, reason, body = http_probe(args.ip, args.whoami, "http", "/")
        if alive and "Hostname:" in body or "Request served by" in body or code in (200, 301, 302):
            ok(f"HTTP probe whoami ({args.whoami}) -> {code} {reason}")
            passed += 1
        else:
            fail(f"HTTP probe whoami failed: {reason or 'non-200 response'}")
            failed += 1
        if args.https:
            alive, code, reason, _ = http_probe(args.ip, args.whoami, "https", "/")
            if alive:
                ok(f"HTTPS probe whoami ({args.whoami}) -> {code} {reason}")
                passed += 1
            else:
                fail(f"HTTPS probe whoami failed: {reason}")
                failed += 1
    except Exception as e:
        fail(f"whoami check error: {e}")
        failed += 1

    # Optional DNS hints (non-fatal)
    print()
    info("=== Optional DNS hints ===")
    for host in [args.argocd, args.grafana, args.whoami]:
        try:
            ip = socket.gethostbyname(host)
            if ip == args.ip:
                ok(f"DNS {host} -> {ip}")
            else:
                warn(f"DNS {host} -> {ip} (expected {args.ip})")
        except Exception:
            warn(f"DNS {host} not resolvable on this VM (ok if Pi-hole not used by VM)")

    # Summary
    print("\n" + "="*66)
    print("STACK HEALTH SUMMARY")
    print("="*66)
    print(f"{GREEN}{CHECK}{RESET} Passed: {passed}   {YELLOW}{WARN}{RESET} Warn: {warned}   {RED}{CROSS}{RESET} Failed: {failed}")
    if failed == 0:
        print(f"{GREEN}All critical checks passed.{RESET}")
    else:
        print(f"{RED}Some critical checks failed. See items marked with {CROSS}.{RESET}")
        print("Common fixes:")
        print(f" - Ensure kubeconfig server points to https://{args.ip}:6443")
        print("   sudo sed -i 's#https://127.0.0.1:6443#https://{ip}:6443#' /etc/rancher/k3s/k3s.yaml".format(ip=args.ip))
        print(" - Check 'kubectl -n monitoring describe pod <operator-pod>' if operator is stuck.")
        print(" - Verify Pi-hole A records point FQDNs to your node IP, or keep using Host headers.")
    print("="*66)

if __name__ == "__main__":
    main()
