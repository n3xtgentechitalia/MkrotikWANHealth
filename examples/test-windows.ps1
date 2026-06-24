# =====================================================================
#  test-windows.ps1 - Diagnostica raggiungibilita' WAN da PC Windows
#  Generico per qualsiasi rete dietro un MikroTik.
#  Verifica: gateway locale, gateway upstream, uscita Internet,
#  percorso (tracert), perdita per hop (pathping) e test applicativo.
#
#  USO (PowerShell):
#     .\test-windows.ps1 -RouterGw <IP_GATEWAY>
#     .\test-windows.ps1 -RouterGw 192.0.2.1 -Target 1.1.1.1
#     .\test-windows.ps1 -RouterGw 192.0.2.1 -Continuous   # ping continuo
#
#  Se PowerShell blocca lo script:
#     powershell -ExecutionPolicy Bypass -File .\test-windows.ps1 -RouterGw <IP>
# =====================================================================

param(
    [string]$RouterGw   = "",                 # IP del gateway/router upstream da testare
    [string]$Target     = "1.1.1.1",          # destinazione Internet
    [string]$Target2    = "8.8.8.8",          # seconda destinazione
    [string]$SrcAddr    = "",                 # IP sorgente locale (-S) se multihomed
    [switch]$Continuous                       # ping -t verso $Target
)

function Title($t) { Write-Host "`n===== $t =====" -ForegroundColor Cyan }

# 1) Gateway e IP locali
Title "1) Configurazione locale (gateway predefinito)"
$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1).NextHop
if (-not $gw) { $gw = (ipconfig | Select-String "Gateway") }
Write-Host ("Gateway predefinito: {0}" -f $gw)
Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } |
    Format-Table InterfaceAlias, IPv4Address, IPv4DefaultGateway -AutoSize

# se non passato, usa il gateway locale rilevato
if ($RouterGw -eq "" -and $gw) { $RouterGw = $gw }

# opzioni sorgente per ping/tracert (-S funziona solo con IP assegnati al PC)
$srcOpt = @()
if ($SrcAddr -ne "") { $srcOpt = @("-S", $SrcAddr) }

# 2) Ping a scala
Title "2) Ping a scala (gateway locale -> gateway router -> Internet)"
if ($gw) { ping -n 4 $gw }
if ($RouterGw) { ping -n 4 @srcOpt $RouterGw }
ping -n 4 @srcOpt $Target

# 3) Traceroute (percorso completo)
Title "3) Tracert verso $Target (1o hop = tuo gateway)"
tracert -d @srcOpt $Target

# 4) Pathping (perdita pacchetti per hop) - richiede ~30-60s
Title "4) Pathping verso $Target2 (statistiche perdita per hop)"
pathping -n -q 20 -p 100 $Target2

# 5) Test applicativo (se ICMP filtrato a monte)
Title "5) Test TCP/DNS"
Test-NetConnection $Target -Port 443 |
    Format-List ComputerName, RemotePort, TcpTestSucceeded, PingSucceeded
try { Resolve-DnsName google.com -ErrorAction Stop | Select-Object -First 2 Name, IPAddress }
catch { Write-Host "DNS KO: $($_.Exception.Message)" -ForegroundColor Yellow }

# 6) Ping continuo (osserva i flap in tempo reale)
if ($Continuous) {
    Title "6) Ping continuo verso $Target (Ctrl+C per fermare)"
    ping -t @srcOpt $Target
}

Write-Host "`nFatto." -ForegroundColor Green
