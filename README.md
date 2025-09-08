# Surf Timer

Simple surf timer plugin for sourcmod, compatible with Counter-Strike: Source.

This was created out of frustration from setting up the [Shavit Surf Timer](https://github.com/bhopppp/Shavit-Surf-Timer) plugin, I just wanted Speed/Timer functionality without the fluff. I was having issues with many map's zones not working so i've refactored all the zones from [wrldspawn/surf-zones](https://github.com/wrldspawn/surf-zones) to a new format with only Start/End zones.

This is intended for private/casual use and hasnt been tested nor designed for full public server use.

# Requirements

- [Metamod](https://sourcemm.net/downloads.php) v1.12 or higher.
- [Sourcemod](https://sourcemod.net/downloads.php) v1.12 or higher.
- Extension [sm-ripext](https://github.com/ErikMinekus/sm-ripext) for zone api.

# Features

- Speed/Velocity
- Timer (seconds)
- Start/End zones loaded dynamically via API [christ-pher/surf-zones](https://github.com/christ-pher/surf-zones)
- SR/PB records stored via local JSON database

# Install

```
1. Clone the repo
git clone https://github.com/christ-pher/surf-timer.git

2. Move Chris-Surf-Timer.sp to your cstrike/addons/sourcemod/scripting

3. Compile the plugin
./compile.sh Chris-Surf-Timer.sp

4. Copy the compiled plugin to your plugins dir
cp compiled/Chris-Surf-Timer.smx ../plugins

5. Restart your CS:S server
```
# TODO

- [x] Speed/Velocity
- [x] Linear Timer
- [x] API Loaded Start/End Zoning
- [x] Persistent Time/Record Keeping
- [ ] Stage Timer
