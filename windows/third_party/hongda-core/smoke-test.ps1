$ErrorActionPreference = 'Stop'
$p = Start-Process -FilePath '.\HongdaCore.exe' -ArgumentList 'run','-c','test-config.json' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
try {
    $v = Invoke-RestMethod -Uri 'http://127.0.0.1:19090/version'
    Write-Output "version=$($v.version)"
    $proxies = Invoke-RestMethod -Uri 'http://127.0.0.1:19090/proxies'
    Write-Output "proxies=$($proxies | ConvertTo-Json -Compress)"
    $status = curl.exe -s -o NUL -w "%{http_code}" -x "http://127.0.0.1:17890" "https://www.gstatic.com/generate_204"
    Write-Output "proxy-http-status=$status"
    $conn = Invoke-RestMethod -Uri 'http://127.0.0.1:19090/connections'
    Write-Output "total-bytes=$($conn.uploadTotal + $conn.downloadTotal)"
}
finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
