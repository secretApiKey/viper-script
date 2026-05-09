# ErwanScript

## Install

```bash
apt update && apt install -y unzip curl ca-certificates && cd /root && curl -L https://github.com/secretApiKey/viper-script/archive/refs/heads/main.zip -o viper-script.zip && unzip -o viper-script.zip && cd viper-script-main && chmod +x installer.sh install-components.sh && bash installer.sh
```
### Command

```bash
menu
```

## Ports

```text
SSH User: 22
SSH Admin: 2222
SSL / Main Multiplexer: 443
Stunnel: 111
OpenVPN TCP: 1194
OpenVPN UDP: 110
WebSocket Payload: 700, 8880, 8888, 8010, 2052, 2082, 2086, 2095
Xray Public Entry: 443
Squid: 8000, 8080
SlowDNS / DNSTT: 5300
BadVPN-UDPGW: 7300
Hysteria UDP: 36712
Nginx Web: 80, 777
```
