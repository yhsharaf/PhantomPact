# Mirrored enemies following the host (coop.lua ENEMY_GLIDE_CM / ENEMY_SNAP_CM), on a running two-copy session
# (pvp-session.ps1): the same enemy is spawned in both worlds, then the guest's copy is pushed away and its distance to
# the host's copy is sampled. 2 m: left alone. 10 m: glides back to 4 m without a jump. 30 m: jumps at once.
$run = "$PSScriptRoot\pvp-run.ps1"
& $run -I 1 -Cmd 'spawnenemy BP_Monster_MaleThug_Sword_Blue 900' -Wait 2 | Out-Null
& $run -I 2 -Cmd 'spawnenemy BP_Monster_MaleThug_Sword_Blue 900' -Wait 3 | Out-Null
$pair = 'local e,r for n,x in pairs(PBZ.net.remoteEnemies or {}) do for _,c in ipairs(PBZ.game.listEnemies(true)) do if c:GetFullName() ~= nil then e=c r=x end end end'
# Sampled inside the game every 100 ms: each read over the mod's command file takes a second or more.
function Sample([string]$Name, [double]$Push) {
    "--- $Name"
    $code = "eval $pair if not e then return 'no enemy pair' end e:K2_SetActorLocation({X=r.X+$Push,Y=r.Y,Z=r.Z},false,{},true) local n,out=0,{} LoopAsync(100,function() n=n+1 local done=n>20 ExecuteInGameThread(function() local a=e:K2_GetActorLocation() local q=PBZ.net.remoteEnemies local x for _,v in pairs(q) do x=v end out[#out+1]=string.format('%.0f',math.sqrt((a.X-x.X)^2+(a.Y-x.Y)^2)) if done and out[1] then PBZ.log('glide samples: '..table.concat(out,' ')) out={} end end) return done end) return 'pushed'"
    & $run -I 2 -Cmd $code -Wait 3.5
}
Sample 'left alone (2 m)' 200
Sample 'glide (10 m)' 1000
Sample 'glide (18 m)' 1800
Sample 'jump (30 m)' 3000
