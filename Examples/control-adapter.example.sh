#!/bin/zsh
set -euo pipefail

# Synthetic, read-only adapter for the public UI contract.
# Replace this file only after reviewing the permissions and ownership checks
# of the adapter you intend to use. It deliberately performs no mutations.

case "${1:-machine}" in
  machine)
    print "state=unknown"
    print "detail=未配置公开示例适配器"
    print "loaded=false"
    print "running=false"
    print "ready=false"
    print "autostart=false"
    print "autostart_mixed=false"
    print "a_state=unknown"
    print "a_detail=示例适配器仅提供只读占位状态"
    print "a_running=false"
    print "a_ready=false"
    print "a_tunnel_count=0"
    print "a_server_count=0"
    print "a_cloudflared_cpu=0"
    print "a_autostart=false"
    print "a_desired=false"
    print "a_hostname=${CODEXPRO_A_HOST:-line-a.example.invalid}"
    print "a_port=0"
    print "b_state=unknown"
    print "b_detail=示例适配器仅提供只读占位状态"
    print "b_running=false"
    print "b_ready=false"
    print "b_tunnel_count=0"
    print "b_server_count=0"
    print "b_cloudflared_cpu=0"
    print "b_autostart=false"
    print "b_desired=false"
    print "b_hostname=${CODEXPRO_B_HOST:-line-b.example.invalid}"
    print "b_port=0"
    ;;
  diagnose)
    print "公开示例适配器未连接任何线路。"
    ;;
  *)
    print -u2 "公开示例适配器拒绝修改动作：${1}"
    exit 64
    ;;
esac
