Script to install m8c on your R36s running dArkOS:

- installs precompiled libSDL3 on sdl2-backend if needed (https://github.com/bmdhacks/SDL/tree/sdl2-backend)
- installs m8 headless client v2.2.3 (https://github.com/laamaa/m8c)
- creates launcher script to re-route audio from Teensy to internal Speaker/Headphones jack
- also lets you close m8c via pressing select & start
- creates udev rule for Teensy communication

Simply download install_m8c.sh to your sd card in tools.<br>
Connect to the internet and navigate to it: Start > Options > Tools<br>
The starter is also located in this path.
