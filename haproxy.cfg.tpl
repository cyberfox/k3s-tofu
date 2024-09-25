global
    log /dev/log    local0
    log /dev/log    local1 notice
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend kubernetes
    bind *:6443
    default_backend kubernetes-backend

backend kubernetes-backend
%{ for ip in master_ips ~}
    server master-${ip} ${ip}:6443 check check-ssl verify none fall 3 rise 2
%{ endfor ~}
