# Partner on the map, on a running two-copy session (pvp-session.ps1): moves copy 2 away, opens the map on copy 1,
# reports what mapicon.lua placed and takes a screenshot. -Key is the game's map key.
param([string]$Shot = "$env:TEMP\pbz-map.png", [string]$Key = 'M', [double]$Forward = 2500, [double]$Yaw = 90, [switch]$Close)
$run = "$PSScriptRoot\pvp-run.ps1"
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$move = "eval local pc,me=PBZ.getPlayer1() local l=me:K2_GetActorLocation() me:K2_SetActorLocation({X=l.X+$Forward,Y=l.Y,Z=l.Z+20},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=$Yaw,Roll=0},false) return 'moved'"
& $run -I 2 -Cmd $move -Wait 2
Select-GameInstance -ProcessId @($state.Games)[0] -Instance 1; Show-Game
Start-Sleep -Milliseconds 500
Send-GameKey $Key
Start-Sleep 3
$info = 'eval local out={} for _,w in ipairs(FindAllOf("WB_MapNew_C") or {}) do out[#out+1]="map visible="..tostring(w:IsVisible()) end local ms=FindFirstOf("MapSubsystem") out[#out+1]="mapId="..tostring(ms and ms:GetCurrentMapID()) local t=PBZ.net.target out[#out+1]="partner "..tostring(t and t.X).." same="..tostring(t and t.Map==PBZ.net.localMap) local n=0 for _,w in ipairs(FindAllOf("W_PaintSize_C") or {}) do n=n+1 end out[#out+1]="paint widgets "..n return table.concat(out," | ")'
& $run -I 1 -Cmd $info -Wait 1
Save-GameScreenshot $Shot -Scale 0.5 | Out-Null
"screenshot: $Shot"
if ($Close) { Send-GameKey ESC }
