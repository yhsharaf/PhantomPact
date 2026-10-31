# Revive on a running two-copy session (pvp-session.ps1), with copy 2 going down and copy 1 reviving: docs/REVIVE.md.
# 1st down cleared with real swings (timed), then a 2nd down left alone until the 15 s timer kills copy 2.
param([string]$Shots = $env:TEMP)
$run = "$PSScriptRoot\pvp-run.ps1"
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
function Show-Log($t, [string]$Pattern) { Get-ModLog -Since $t -Last 500 | Where-Object { $_ -match $Pattern -and $_ -notmatch '\] > ' } | ForEach-Object { '  ' + ($_ -replace '^.*?\[(PBZCoop#?2?)\] ', '[$1] ') } }
foreach ($i in 1, 2) { & $run -I $i -Cmd 'revive on' -Wait 1 }
& $run -I 1 -Cmd 'revive trace' -Wait 1 | Out-Null
Start-Sleep 1
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*170,l.Y+math.sin(math.rad(r))*170 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) return "placed"'
& $run -I 2 -Cmd $place -Wait 1
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) return "faced"'
& $run -I 1 -Cmd $face -Wait 1
$t0 = Get-Date
"--- 1st down"
& $run -I 2 -Cmd 'eval local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p,1) return "health 1"' -Wait 1.5
& $run -I 2 -Cmd 'revive' -Wait 1
& $run -I 1 -Cmd 'revive' -Wait 1
Select-GameInstance -ProcessId @($state.Games)[1] -Instance 2; Show-Game; Start-Sleep 1
Save-GameScreenshot "$Shots\ring-downed.png" -Scale 0.5 | Out-Null
Select-GameInstance -ProcessId @($state.Games)[0] -Instance 1; Show-Game; Start-Sleep 1
Save-GameScreenshot "$Shots\ring-partner.png" -Scale 0.5 | Out-Null
$rect = New-Object GameDriver.Native+RECT
[void][GameDriver.Native]::GetWindowRect((Get-GameWindow), [ref]$rect)
[GameDriver.Native]::SetCursorPos(($rect.Left+$rect.Right)/2, ($rect.Top+$rect.Bottom)/2) | Out-Null
for ($i=0; $i -lt 24; $i++) { [GameDriver.Native]::mouse_event(0x2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 40; [GameDriver.Native]::mouse_event(0x4,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 110 }
Start-Sleep 1
& $run -I 2 -Cmd 'eval local _,p=PBZ.getPlayer1() local h,m=PBZ.game.getHealth(p) return "copy 2 health "..h.."/"..m' -Wait 1
& $run -I 2 -Cmd 'revive' -Wait 1
Show-Log $t0 'Revive: AM_|Revive: [a-z]+ |back on|revive:'
"--- 2nd down, left alone"
$t1 = Get-Date
& $run -I 2 -Cmd 'eval local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p,1) return "health 1"' -Wait 1.5
& $run -I 2 -Cmd 'revive' -Wait 1
Start-Sleep 16
& $run -I 2 -Cmd 'eval local _,p=PBZ.getPlayer1() local h,m=PBZ.game.getHealth(p) return "copy 2 health "..tostring(h).."/"..tostring(m).." dead="..tostring(p and PBZ.game.isDead(p))' -Wait 1
& $run -I 1 -Cmd 'revive' -Wait 1
Show-Log $t1 'Revive|back on|down:|revive:|respawn|Respawn|down or gone'
