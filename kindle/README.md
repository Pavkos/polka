# «Полка» on the Kindle's own screen

A jailbroken Kindle lists every `.sh` file in `/mnt/us/documents` as a book
(a *scriptlet*) and runs it when it is tapped. KPM installs KOReader's own
launcher this way (`documents/KOReader.sh`, which runs
`kpm launch koreader --asap`, i.e. `cd /mnt/us && sh koreader/koreader.sh --asap`).

Polka ships its own scriptlet, `polka.koplugin/kindle/polka.sh`:

- headers `# Name: Полка`, `# Icon: <plugin>/kindle/icon.png` and
  `# DontUseFBInk` (the script's output never reaches the screen);
- it reads the screen size (`eips -i`), paints the matching
  `kindle/splash-WxH.png` with `eips -f -g` (FBInk from `/var/tmp` if eips
  cannot; `/mnt/us` is mounted `noexec`);
- then starts KOReader exactly as KPM does, `koreader.sh --asap` from
  `/mnt/us`, without `--kual` and with its output sent to `/dev/null`, so
  the «Starting KOReader . . .» line is never drawn.

## How it gets installed

By Polka, on request: О Полке → «Полка на экране Kindle» → «Добавить»
copies the script to `/mnt/us/documents/polka.sh` with the real paths filled
in (`@@KOREADER_DIR@@`, `@@POLKA_DIR@@`). «Убрать» deletes it (only a file
that carries the launcher's marker line). After a Polka update an installed
launcher is refreshed by itself. Nothing is installed without the tap.

To remove it by hand: delete `documents/polka.sh` on the Kindle.

Later, the same files can become a KPM package (`polka`), next to the
plugin package:

```
manifest.json   {"manifest_version": 2, "id": "polka-launcher", "name": "Полка",
                 "version": [1, 7, 0], "dependencies": ["koreader"],
                 "supported_platforms": ["kindlehf"]}
install.sh      sed the two @@ paths into scriptlets/polka.sh,
                mv it to /mnt/us/documents/polka.sh
uninstall.sh    rm -f /mnt/us/documents/polka.sh
```

## The pictures

`polka.koplugin/kindle/splash-*.png` (600×800, 758×1024, 1072×1448,
1236×1648, 1264×1680, 1860×2480) and `icon.png` are generated from the
approved mockup (kindle-splash) by

```
python3 kindle/make_images.py <folder with NotoSerif-Bold.ttf and NotoSans-Regular.ttf> polka.koplugin/kindle
```

(KOReader ships both fonts in `fonts/noto`). 8-bit grayscale, as eips
wants them. Polka paints the same picture before it restarts itself
(polka_splash.lua), so a restart looks the same as a launch.

This cannot be tried in the emulator: the script was checked with a stub
`eips` and a stub `koreader.sh`, not on a Kindle yet.
